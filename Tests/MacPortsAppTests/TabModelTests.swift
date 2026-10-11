import Foundation
import Testing

@testable import MacPortsApp
@testable import PortsKit

extension Gates {
  /// `pass` with the key "`prefix` n" for the nth call, so each load of the
  /// same query can be held or released on its own.
  func passNumbered(_ prefix: String) async throws {
    let n = calls.filter { $0.hasPrefix(prefix + " ") }.count + 1
    try await pass("\(prefix) \(n)")
  }
}

@Suite struct FreshnessTests {
  @Test func staleUntilLoaded() {
    var freshness = Freshness()
    #expect(freshness.isStale)
    freshness.markLoaded(freshness.begin())
    #expect(!freshness.isStale)
  }

  @Test func invalidateMakesItStale() {
    var freshness = Freshness()
    freshness.markLoaded(freshness.begin())
    freshness.invalidate()
    #expect(freshness.isStale)
  }

  @Test func loadThatStartedBeforeInvalidationIsNotFresh() {
    var freshness = Freshness()
    let token = freshness.begin()
    freshness.invalidate()
    freshness.markLoaded(token)
    #expect(freshness.isStale)
    freshness.markLoaded(freshness.begin())
    #expect(!freshness.isStale)
  }

  @Test func expiresAfterMaxAge() async throws {
    var freshness = Freshness(maxAge: .milliseconds(20))
    freshness.markLoaded(freshness.begin())
    #expect(!freshness.isStale)
    try await Task.sleep(for: .milliseconds(40))
    #expect(freshness.isStale)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct TabModelTests {
  struct Failure: Error {}

  let gates = Gates()

  /// Each load returns one port named after the call ("outdated 1", ...).
  func makeOutdated(failing: Set<String> = []) -> OutdatedModel {
    let gates = gates
    return OutdatedModel {
      try await gates.passNumbered("outdated")
      let n = await gates.calls.filter { $0.hasPrefix("outdated ") }.count
      if failing.contains("outdated \(n)") { throw Failure() }
      return [OutdatedPort(name: "port\(n)", installedVersion: "1.0_0", availableVersion: "2.0_0")]
    }
  }

  func outdatedCalls() async -> Int { await gates.calls.filter { $0.hasPrefix("outdated") }.count }

  @Test func revisitingReusesFreshData() async throws {
    let model = makeOutdated()
    await gates.open("outdated 1", "outdated 2")
    await model.loadIfStale()
    await model.loadIfStale()
    #expect(model.ports.map(\.name) == ["port1"])
    #expect(await outdatedCalls() == 1)
  }

  @Test func invalidatedDataIsLoadedOnTheNextVisit() async throws {
    let model = makeOutdated()
    await gates.open("outdated 1", "outdated 2")
    await model.loadIfStale()
    model.invalidate()
    await model.loadIfStale()
    #expect(model.ports.map(\.name) == ["port2"])
    #expect(await outdatedCalls() == 2)
  }

  /// A command that finishes while the list is loading may have changed it.
  @Test func invalidationDuringALoadForcesAnotherLoad() async throws {
    let model = makeOutdated()
    let load = Task { await model.load() }
    #expect(try await gates.waitForCall("outdated 1"))
    model.invalidate()
    await gates.open("outdated 1", "outdated 2")
    await load.value
    await model.loadIfStale()
    #expect(await outdatedCalls() == 2)
  }

  @Test func cancelledLoadKeepsWhatWasShown() async throws {
    let model = makeOutdated()
    await gates.open("outdated 1")
    await model.load()
    let reload = Task { await model.load() }
    #expect(try await gates.waitForCall("outdated 2"))
    reload.cancel()
    await reload.value
    #expect(model.ports.map(\.name) == ["port1"])
    #expect(model.errorMessage == nil)
    #expect(!model.isLoading)
  }

  @Test func failedLoadIsRetriedOnTheNextVisit() async throws {
    let model = makeOutdated(failing: ["outdated 1"])
    await gates.open("outdated 1", "outdated 2")
    await model.loadIfStale()
    #expect(model.errorMessage != nil)
    #expect(model.ports.isEmpty)
    await model.loadIfStale()
    #expect(model.errorMessage == nil)
    #expect(model.ports.map(\.name) == ["port2"])
  }

  @Test func selectionsAreReusedUntilInvalidated() async throws {
    let gates = gates
    let model = SelectionsModel {
      try await gates.passNumbered("select")
      return [PortSelectGroup(name: "python", selected: "python313", options: ["python313"])]
    }
    await gates.open("select 1", "select 2")
    await model.loadIfStale()
    await model.loadIfStale()
    #expect(await gates.calls == ["select 1"])
    model.invalidate()
    await model.loadIfStale()
    #expect(await gates.calls == ["select 1", "select 2"])
    #expect(model.groups.map(\.name) == ["python"])
  }

  @Test func configurationIsReusedAndSurvivesACancelledReload() async throws {
    let gates = gates
    let model = ConfigurationModel {
      try await gates.passNumbered("version")
      let n = await gates.calls.count
      return MacPortsInfo(
        version: "2.12.\(n)", executablePath: "", prefix: "", dataPath: "",
        applicationsDir: "", sources: [], sourcesConfPath: "", lastSync: nil)
    }
    await gates.open("version 1")
    await model.loadIfStale()
    await model.loadIfStale()
    #expect(model.info?.version == "2.12.1")

    let reload = Task { await model.load() }
    #expect(try await gates.waitForCall("version 2"))
    reload.cancel()
    await reload.value
    #expect(model.info?.version == "2.12.1")
    #expect(model.failure == nil)
  }

  @Test func diagnoseRunsOnceUntilAskedAgain() async throws {
    let gates = gates
    let model = HealthModel {
      try await gates.passNumbered("diagnose")
      return []
    }
    // "diagnose 3" is open so a wrong extra run fails fast instead of hanging.
    await gates.open("diagnose 1", "diagnose 2", "diagnose 3")
    await model.checkIfNeeded()
    await model.checkIfNeeded()
    #expect(await gates.calls == ["diagnose 1"])
    #expect(model.findings == [])
    await model.check()
    #expect(await gates.calls == ["diagnose 1", "diagnose 2"])
  }

  /// Leaving the Health tab during the first check cancels it; the next visit
  /// runs it again without showing an error.
  @Test func cancelledDiagnoseRunsAgainOnTheNextVisit() async throws {
    let gates = gates
    let model = HealthModel {
      try await gates.passNumbered("diagnose")
      return []
    }
    let first = Task { await model.checkIfNeeded() }
    #expect(try await gates.waitForCall("diagnose 1"))
    first.cancel()
    await first.value
    #expect(model.failure == nil)
    #expect(model.findings == nil)

    await gates.open("diagnose 2")
    await model.checkIfNeeded()
    #expect(model.findings == [])
  }

  @Test func registryReadabilityIsCheckedOnLoad() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ports-app-db-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(
      atPath: dir + "/registry", withIntermediateDirectories: true)
    func model(_ dataPath: String) -> ConfigurationModel {
      ConfigurationModel {
        MacPortsInfo(
          version: "2.12.6", executablePath: "", prefix: "", dataPath: dataPath,
          applicationsDir: "", sources: [], sourcesConfPath: "", lastSync: nil)
      }
    }
    let missing = model(dir)
    await missing.load()
    #expect(!missing.registryReadable)

    FileManager.default.createFile(atPath: dir + "/registry/registry.db", contents: Data())
    let present = model(dir)
    await present.load()
    #expect(present.registryReadable)
  }
}

@MainActor
@Suite struct OutdatedLookupTests {
  @Test func onlyTheActiveVersionHasAnUpdate() {
    let model = OutdatedModel { [] }
    model.ports = [
      OutdatedPort(name: "zlib", installedVersion: "1.3_0", availableVersion: "1.3.1_0")
    ]
    let active = InstalledPort(
      name: "zlib", version: "1.3", revision: 0, variants: [], isActive: true)
    let inactive = InstalledPort(
      name: "zlib", version: "1.2", revision: 0, variants: [], isActive: false)
    let other = InstalledPort(name: "xz", version: "5.4", revision: 0, variants: [], isActive: true)
    #expect(model.update(for: active)?.availableVersion == "1.3.1_0")
    #expect(model.update(for: inactive) == nil)
    #expect(model.update(for: other) == nil)
  }
}
