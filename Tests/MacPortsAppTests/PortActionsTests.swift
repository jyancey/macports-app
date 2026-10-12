// PortActionsTests.swift - Tests for the port actions, using fake port commands.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Testing

@testable import MacPortsApp
@testable import PortsKit

/// Records the commands it is asked to run instead of running `port`.
actor FakePortCommands: PortCommandRunner {
  struct Failure: Error {}

  private(set) var calls: [String] = []
  /// Variants returned for each port (none when missing).
  var variants: [String: [PortVariant]] = [:]
  var failing = false

  func setVariants(_ list: [PortVariant], for name: String) { variants[name] = list }
  func setFailing(_ value: Bool) { failing = value }

  private func record(_ call: String) throws {
    calls.append(call)
    if failing { throw Failure() }
  }

  func variants(of name: String) async throws -> [PortVariant] { variants[name] ?? [] }

  func install(
    _ name: String, variantFlags: [String],
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    try record((["install", name] + variantFlags).joined(separator: " "))
  }

  func upgrade(_ names: [String], onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  { try record("upgrade " + names.joined(separator: " ")) }

  func upgradeAll(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
    try record("upgrade outdated")
  }

  func uninstall(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  { try record("uninstall \(name)") }

  func uninstall(
    _ ports: [InstalledPort], onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    try record("uninstall " + ports.map { "\($0.name) \($0.versionSpec)" }.joined(separator: " "))
  }

  func uninstallInactive(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
    try record("uninstall inactive")
  }

  func activate(_ port: InstalledPort, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  { try record("activate \(port.name) \(port.versionSpec)") }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PortActionsTests {
  let runner = FakePortCommands()
  let log = ActivityLog()
  /// Counts reloads after commands.
  final class Reloads { var count = 0 }
  let reloads = Reloads()

  func makeActions() -> PortActions {
    let reloads = reloads
    return PortActions(activity: log, runner: runner) { reloads.count += 1 }
  }

  @Test func portWithoutVariantsInstallsAtOnce() async {
    let actions = makeActions()
    await actions.install("zlib")
    #expect(await runner.calls == ["install zlib"])
    #expect(actions.installRequest == nil)
    #expect(reloads.count == 1)
    #expect(log.chunks.joined().hasPrefix("$ sudo port install zlib\n"))
  }

  @Test func portWithVariantsAsksFirst() async {
    let actions = makeActions()
    await runner.setVariants(
      [PortVariant(name: "universal", summary: "", isDefault: false, requires: [], conflicts: [])],
      for: "git")
    await actions.install("git")
    #expect(actions.installRequest?.name == "git")
    #expect(await runner.calls.isEmpty)

    await actions.install("git", flags: ["+universal"])
    #expect(await runner.calls == ["install git +universal"])
  }

  @Test func uninstallWaitsForConfirmation() async {
    let actions = makeActions()
    actions.requestUninstall("zlib")
    #expect(actions.uninstallRequest == "zlib")
    #expect(await runner.calls.isEmpty)

    await actions.confirmUninstall("zlib")
    #expect(actions.uninstallRequest == nil)
    #expect(await runner.calls == ["uninstall zlib"])
  }

  @Test func listsReloadAfterAFailedCommand() async {
    let actions = makeActions()
    await runner.setFailing(true)
    await actions.upgrade("zlib")
    #expect(log.lastRunFailed)
    #expect(reloads.count == 1)
  }

  @Test func removingAVersionNamesItExactly() async {
    let actions = makeActions()
    let port = InstalledPort(
      name: "zlib", version: "1.3", revision: 1, variants: ["universal"], isActive: false)
    await actions.remove(port)
    #expect(await runner.calls == ["uninstall zlib @1.3_1+universal"])
    #expect(log.chunks.joined().hasPrefix("$ sudo port uninstall zlib @1.3_1+universal\n"))
  }

  @Test func activatingWaitsForConfirmation() async {
    let actions = makeActions()
    let port = InstalledPort(
      name: "zlib", version: "1.2", revision: 0, variants: [], isActive: false)
    actions.requestActivate(port)
    #expect(actions.activateRequest == port)
    #expect(await runner.calls.isEmpty)

    await actions.confirmActivate(port)
    #expect(actions.activateRequest == nil)
    #expect(await runner.calls == ["activate zlib @1.2_0"])
    #expect(reloads.count == 1)
  }

  @Test func batchesRunAsOneCommand() async {
    let actions = makeActions()
    await actions.upgrade(["zlib", "xz"])
    let old = [
      InstalledPort(name: "zlib", version: "1.2", revision: 0, variants: [], isActive: false),
      InstalledPort(name: "xz", version: "5.2", revision: 1, variants: [], isActive: false),
    ]
    await actions.remove(old)
    #expect(await runner.calls == ["upgrade zlib xz", "uninstall zlib @1.2_0 xz @5.2_1"])
    #expect(reloads.count == 2)
    #expect(log.chunks.joined().contains("$ sudo port upgrade zlib xz\n"))
  }

  @Test func emptyBatchesDoNothing() async {
    let actions = makeActions()
    await actions.upgrade([String]())
    await actions.remove([InstalledPort]())
    #expect(await runner.calls.isEmpty)
    #expect(reloads.count == 0)
  }

  @Test func eachPortInABatchShowsAsWorking() async throws {
    let actions = makeActions()
    let gates = Gates()
    let gated = PortActions(activity: log, runner: GatedUpgrades(gates: gates)) {}
    let upgrade = Task { await gated.upgrade(["zlib", "xz"]) }
    #expect(try await gates.waitForCall("upgrade"))
    #expect(gated.isWorking(on: "zlib") && gated.isWorking(on: "xz"))
    #expect(!gated.isWorking(on: "git"))
    #expect(!actions.isWorking(on: "zlib"))
    await gates.open("upgrade")
    await upgrade.value
    #expect(!gated.isWorking(on: "zlib"))
  }

  @Test func removingAllInactiveVersionsWaitsForConfirmation() async {
    let actions = makeActions()
    actions.requestRemoveAllInactive()
    #expect(actions.removeAllInactiveRequested)
    #expect(await runner.calls.isEmpty)

    await actions.confirmRemoveAllInactive()
    #expect(!actions.removeAllInactiveRequested)
    #expect(await runner.calls == ["uninstall inactive"])
  }

  @Test func progressTextFollowsThePortOutput() async throws {
    let actions = makeActions()
    let gates = Gates()
    #expect(actions.progressText(for: "zlib", fallback: "Working…") == "Working…")
    let run = Task {
      await log.run("sudo port upgrade zlib", name: "zlib") { out in
        out("--->  Computing dependencies for zlib\n--->  Building zlib\n")
        try await gates.pass("built")
      }
    }
    #expect(try await until { log.progress["zlib"] != nil })
    #expect(actions.progressText(for: "zlib", fallback: "Working…") == "Building…")
    #expect(actions.progressText(for: "xz", fallback: "Working…") == "Working…")
    await gates.open("built")
    _ = await run.value
    #expect(actions.progressText(for: "zlib", fallback: "Working…") == "Working…")
  }

  @Test func nothingStartsWhileACommandIsRunning() async throws {
    let actions = makeActions()
    let gates = Gates()
    let busy = Task {
      await log.run("busy", name: "busy") { _ in try await gates.pass("busy") }
    }
    #expect(try await until { log.isRunning })
    #expect(!actions.canStart("zlib"))
    await actions.upgradeAll()
    actions.requestUninstall("zlib")
    #expect(actions.uninstallRequest == nil)
    actions.requestRemoveAllInactive()
    #expect(!actions.removeAllInactiveRequested)
    #expect(await runner.calls.isEmpty)
    #expect(reloads.count == 0)
    await gates.open("busy")
    _ = await busy.value
  }
}

/// Holds every upgrade until the gate "upgrade" opens.
struct GatedUpgrades: PortCommandRunner {
  let gates: Gates
  func variants(of name: String) async throws -> [PortVariant] { [] }
  func install(
    _ name: String, variantFlags: [String],
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {}
  func upgrade(_ names: [String], onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  { try await gates.pass("upgrade") }
  func upgradeAll(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {}
  func uninstall(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  {}
  func uninstall(
    _ ports: [InstalledPort], onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {}
  func uninstallInactive(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {}
  func activate(_ port: InstalledPort, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  {}
}

@MainActor @Test func batchSummaryListsTheFirstItemsAndCountsTheRest() {
  #expect(BatchSelectionView.summary(["a", "b"], limit: 3) == "a\nb")
  #expect(BatchSelectionView.summary(["a", "b", "c", "d", "e"], limit: 3) == "a\nb\nc\nand 2 more")
}
