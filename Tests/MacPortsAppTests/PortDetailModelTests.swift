import PortsKit
import Testing

@testable import MacPortsApp

struct FakeSource: PortDetailSource {
  struct Failure: Error {}
  let gates: Gates
  var failingInfo: Set<String> = []

  func info(for name: String) async throws -> PortInfo {
    try await gates.pass("info \(name)")
    if failingInfo.contains(name) { throw Failure() }
    return PortInfo(name: name, version: "1.0", revision: 2, libDependencies: ["zlib"])
  }
  func contents(of name: String) async throws -> [String] {
    try await gates.pass("contents \(name)")
    return ["/opt/local/bin/\(name)"]
  }
  func dependents(of name: String) async throws -> [String] {
    try await gates.pass("dependents \(name)")
    return ["needs-\(name)"]
  }
  func dependencyTree(of name: String) async throws -> [PortInfoParser.DependencyNode] {
    try await gates.pass("rdeps \(name)")
    return [PortInfoParser.DependencyNode(id: 0, name: "zlib")]
  }
  func variants(of name: String) async throws -> [PortVariant] {
    try await gates.pass("variants \(name)")
    return [PortVariant(name: "x11", isDefault: true), PortVariant(name: "quartz")]
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PortDetailModelTests {
  let gates = Gates()

  func makeModel(failingInfo: Set<String> = [], debounce: Duration = .zero) -> PortDetailModel {
    let gates = gates
    return PortDetailModel(
      source: FakeSource(gates: gates, failingInfo: failingInfo),
      binaryCheck: { name, version, revision, variants in
        let flags = variants.joined(separator: ",")
        try? await gates.pass("binary \(name) \(version)_\(revision) \(flags)")
        return .available
      },
      debounce: debounce)
  }

  func infoName(_ model: PortDetailModel) -> String? {
    if case .loaded(let info) = model.info { info.name } else { nil }
  }

  @Test func infoAppearsWithoutWaitingForSlowerQueries() async throws {
    let model = makeModel()
    let load = Task { await model.load("aom", isInstalled: true) }
    await gates.open("info aom")
    #expect(try await until { infoName(model) == "aom" })
    #expect(model.files == .loading)
    #expect(model.dependents == .loading)

    await gates.open("contents aom")
    #expect(try await until { model.files == .loaded(["/opt/local/bin/aom"]) })
    #expect(model.dependents == .loading)

    await gates.open("dependents aom", "variants aom", "binary aom 1.0_2 x11")
    await load.value
    #expect(model.dependents == .loaded(["needs-aom"]))
    #expect(model.binary == .available)
  }

  @Test func binaryCheckNeedsOnlyInfoAndDefaultVariants() async throws {
    let model = makeModel()
    let load = Task { await model.load("aom", isInstalled: true) }
    await gates.open("info aom", "variants aom", "binary aom 1.0_2 x11")
    #expect(try await until { model.binary == .available })
    #expect(model.files == .loading)
    #expect(model.dependents == .loading)

    await gates.open("contents aom", "dependents aom")
    await load.value
  }

  @Test func loadLeavesTheDependencyTreeUntilRequested() async throws {
    let model = makeModel()
    await gates.open(
      "info aom", "variants aom", "contents aom", "dependents aom", "binary aom 1.0_2 x11")
    await model.load("aom", isInstalled: true)
    #expect(model.tree == nil)
    #expect(await !gates.calls.contains("rdeps aom"))

    let tree = Task { await model.loadTree("aom") }
    #expect(try await until { model.tree == .loading })
    await gates.open("rdeps aom")
    await tree.value
    #expect(model.tree == .loaded([PortInfoParser.DependencyNode(id: 0, name: "zlib")]))
  }

  @Test func cancellingTheTreeLetsItBeRequestedAgain() async throws {
    let model = makeModel()
    let first = Task { await model.loadTree("aom") }
    #expect(try await until { model.tree == .loading })
    first.cancel()
    await gates.open("rdeps aom")
    await first.value
    #expect(model.tree == nil)

    await model.loadTree("aom")
    #expect(model.tree == .loaded([PortInfoParser.DependencyNode(id: 0, name: "zlib")]))
  }

  /// Installing reloads the same port (isInstalled flips) while its tree may be expanded.
  @Test func reloadingAPortKeepsItsTree() async throws {
    let model = makeModel()
    let tree = [PortInfoParser.DependencyNode(id: 0, name: "zlib")]
    await gates.open(
      "info aom", "variants aom", "contents aom", "dependents aom", "binary aom 1.0_2 x11",
      "rdeps aom")
    await model.load("aom", isInstalled: false)
    await model.loadTree("aom")
    await model.load("aom", isInstalled: true)
    #expect(model.tree(for: "aom") == .loaded(tree))
    #expect(model.tree(for: "zlib") == nil)

    await model.loadTree("aom")
    #expect(await gates.calls.filter { $0 == "rdeps aom" }.count == 1)
  }

  @Test func portsThatAreNotInstalledSkipFilesAndDependents() async throws {
    let model = makeModel()
    await gates.open(
      "info aom", "variants aom", "binary aom 1.0_2 x11", "contents aom", "dependents aom")
    await model.load("aom", isInstalled: false)
    #expect(model.files == .loaded([]))
    #expect(model.dependents == .loaded([]))
    #expect(
      Set(await gates.calls) == ["info aom", "variants aom", "binary aom 1.0_2 x11"])
  }

  @Test func failedInfoSkipsTheBinaryCheck() async throws {
    let model = makeModel(failingInfo: ["aom"])
    await gates.open("info aom", "variants aom", "contents aom", "dependents aom")
    await model.load("aom", isInstalled: true)
    guard case .failed = model.info else {
      Issue.record("expected info to fail")
      return
    }
    #expect(model.binary == nil)
    #expect(await !gates.calls.contains { $0.hasPrefix("binary") })
  }

  @Test func cancelledLoadNeverOverwritesTheNewerPort() async throws {
    let model = makeModel()
    let old = Task { await model.load("old", isInstalled: true) }
    #expect(try await until { model.info == .loading })
    #expect(try await gates.waitForCall("info old"))
    old.cancel()

    let new = Task { await model.load("new", isInstalled: true) }
    await gates.open(
      "info new", "variants new", "contents new", "dependents new", "binary new 1.0_2 x11")
    await new.value
    // The old port's queries finish after the new port is shown.
    await gates.open("info old", "variants old", "contents old", "dependents old")
    await old.value

    #expect(infoName(model) == "new")
    #expect(model.files == .loaded(["/opt/local/bin/new"]))
    #expect(await !gates.calls.contains { $0.hasPrefix("binary old") })
  }

  @Test func portsPassedOverQuicklyAreNeverQueried() async throws {
    let model = makeModel(debounce: .milliseconds(300))
    for name in ["a", "b", "c"] {
      let passed = Task { await model.load(name, isInstalled: true) }
      // Cancel the way a selection change does: after the load has started.
      try await Task.sleep(for: .milliseconds(30))
      passed.cancel()
      await passed.value
    }
    await gates.open("info d", "variants d", "contents d", "dependents d", "binary d 1.0_2 x11")
    await model.load("d", isInstalled: true)
    #expect(infoName(model) == "d")
    #expect(await gates.calls.allSatisfy { $0.hasSuffix(" d") || $0.hasPrefix("binary d") })
  }
}
