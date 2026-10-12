// PortDetailCacheTests.swift - Tests for the port detail cache.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import PortsKit
import Testing

@testable import MacPortsApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PortDetailCacheTests {
  let gates = Gates()
  let tree = [PortInfoParser.DependencyNode(id: 0, name: "zlib")]

  /// Every fake query for `aom` is open; `binary` is what the archive check answers.
  func makeModel(
    binary: BinaryAvailability = .available, failingInfo: Set<String> = []
  ) async -> PortDetailModel {
    let gates = gates
    await gates.open(
      "info aom", "variants aom", "contents aom", "dependents aom", "rdeps aom",
      "binary aom")
    return PortDetailModel(
      source: FakeSource(gates: gates, failingInfo: failingInfo),
      binaryCheck: { name, _, _, _ in
        try? await gates.pass("binary \(name)")
        return binary
      },
      debounce: .zero)
  }

  func calls() async -> [String] { await gates.calls }

  @Test func showingAPortAgainRunsNoQueries() async throws {
    let cache = PortDetailCache()
    await makeModel().load("aom", isInstalled: true, cache: cache)
    let first = await calls()
    #expect(
      Set(first) == ["info aom", "variants aom", "contents aom", "dependents aom", "binary aom"])

    // A new detail pane (another selection) shows the cached results at once.
    let model = await makeModel()
    await model.load("aom", isInstalled: true, cache: cache)
    #expect(await calls() == first)
    #expect(model.files == .loaded(["/opt/local/bin/aom"]))
    #expect(model.dependents == .loaded(["needs-aom"]))
    #expect(model.binary == .available)
    if case .loaded(let info) = model.info {
      #expect(info.name == "aom")
    } else {
      Issue.record("expected cached info")
    }
  }

  /// After an install only the installed-port queries are new.
  @Test func onlyMissingResultsAreQueried() async throws {
    let cache = PortDetailCache()
    let model = await makeModel()
    await model.load("aom", isInstalled: false, cache: cache)
    let before = await calls().count
    await model.load("aom", isInstalled: true, cache: cache)
    #expect(Set(await calls().dropFirst(before)) == ["contents aom", "dependents aom"])
  }

  @Test func clearedCacheIsQueriedAgain() async throws {
    let cache = PortDetailCache()
    let model = await makeModel()
    await model.load("aom", isInstalled: true, cache: cache)
    cache.removeAll()
    await model.load("aom", isInstalled: true, cache: cache)
    #expect(await calls().filter { $0 == "info aom" }.count == 2)
  }

  @Test func expiredResultsAreQueriedAgain() async throws {
    let cache = PortDetailCache(maxAge: .zero)
    let model = await makeModel()
    await model.load("aom", isInstalled: true, cache: cache)
    try await Task.sleep(for: .milliseconds(5))
    await model.load("aom", isInstalled: true, cache: cache)
    #expect(await calls().filter { $0 == "info aom" }.count == 2)
  }

  @Test func failuresAreNotCached() async throws {
    let cache = PortDetailCache()
    let model = await makeModel(failingInfo: ["aom"])
    await model.load("aom", isInstalled: true, cache: cache)
    #expect(cache["aom"].info == nil)
    await model.load("aom", isInstalled: true, cache: cache)
    #expect(await calls().filter { $0 == "info aom" }.count == 2)
    // What did load is cached.
    #expect(await calls().filter { $0 == "contents aom" }.count == 1)
  }

  /// An unreachable archive site is checked again next time, without
  /// re-running the info and variants queries.
  @Test func unknownBinaryIsCheckedAgain() async throws {
    let cache = PortDetailCache()
    let model = await makeModel(binary: .unknown)
    await model.load("aom", isInstalled: true, cache: cache)
    #expect(model.binary == .unknown)
    let before = await calls().count
    await model.load("aom", isInstalled: true, cache: cache)
    #expect(Array(await calls().dropFirst(before)) == ["binary aom"])
  }

  @Test func dependencyTreeIsCached() async throws {
    let cache = PortDetailCache()
    await makeModel().loadTree("aom", cache: cache)
    let model = await makeModel()
    await model.loadTree("aom", cache: cache)
    #expect(model.tree(for: "aom") == .loaded(tree))
    #expect(await calls() == ["rdeps aom"])
  }

  /// A tree query that finishes just as the tree is collapsed still returns a
  /// result; it was cancelled, so it must not be cached.
  @Test func cancelledTreeIsNotCached() async throws {
    struct LateTree: PortDetailSource {
      let base: FakeSource
      func info(for name: String) async throws -> PortInfo { try await base.info(for: name) }
      func contents(of name: String) async throws -> [String] { try await base.contents(of: name) }
      func dependents(of name: String) async throws -> [String] {
        try await base.dependents(of: name)
      }
      func variants(of name: String) async throws -> [PortVariant] {
        try await base.variants(of: name)
      }
      func dependencyTree(of name: String) async throws -> [PortInfoParser.DependencyNode] {
        await base.gates.passIgnoringCancellation("rdeps \(name)")
        return [PortInfoParser.DependencyNode(id: 0, name: "zlib")]
      }
    }
    let cache = PortDetailCache()
    let model = PortDetailModel(
      source: LateTree(base: FakeSource(gates: gates)), binaryCheck: { _, _, _, _ in .available },
      debounce: .zero)
    let load = Task { await model.loadTree("aom", cache: cache) }
    #expect(try await gates.waitForCall("rdeps aom"))
    load.cancel()
    await gates.open("rdeps aom")
    await load.value
    #expect(cache["aom"].tree == nil)
    #expect(model.tree(for: "aom") == nil)
  }
}
