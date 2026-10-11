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

  func upgrade(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  { try record("upgrade \(name)") }

  func upgradeAll(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
    try record("upgrade outdated")
  }

  func uninstall(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  { try record("uninstall \(name)") }

  func uninstall(_ port: InstalledPort, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  { try record("uninstall \(port.name) \(port.versionSpec)") }

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
    #expect(await runner.calls.isEmpty)
    #expect(reloads.count == 0)
    await gates.open("busy")
    await busy.value
  }
}
