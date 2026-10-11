import PortsKit
import SwiftUI

/// The `port` commands that change what is installed. Tests substitute a fake.
protocol PortCommandRunner: Sendable {
  func variants(of name: String) async throws -> [PortVariant]
  func install(
    _ name: String, variantFlags: [String],
    onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws
  func upgrade(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  func upgradeAll(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws
  func uninstall(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  func uninstall(_ port: InstalledPort, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  func uninstallInactive(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws
  func activate(_ port: InstalledPort, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
}

/// Runs each command with a new `PortClient`, so a `port` path or verbose
/// setting changed in Configuration applies to the next command.
struct LivePortCommands: PortCommandRunner {
  func variants(of name: String) async throws -> [PortVariant] {
    try await PortClient().variants(of: name)
  }

  func install(
    _ name: String, variantFlags: [String],
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    try await PortClient().install(name, variantFlags: variantFlags, onOutput: onOutput)
  }

  func upgrade(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  {
    try await PortClient().upgrade(name, onOutput: onOutput)
  }

  func upgradeAll(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
    try await PortClient().upgradeAll(onOutput: onOutput)
  }

  func uninstall(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  {
    try await PortClient().uninstall(name, onOutput: onOutput)
  }

  func uninstall(_ port: InstalledPort, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  {
    try await PortClient().uninstall(port, onOutput: onOutput)
  }

  func uninstallInactive(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
    try await PortClient().uninstallInactive(onOutput: onOutput)
  }

  func activate(_ port: InstalledPort, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  {
    try await PortClient().activate(port, onOutput: onOutput)
  }
}

/// Starts install, upgrade and uninstall commands for one window, from the
/// detail pane, the toolbar or a table. Commands run through the Activity log,
/// and the lists are reloaded after every command, whether it worked or not
/// (a failed install may still have installed dependencies). It also holds the
/// install-options sheet and uninstall confirmation, which the window presents.
@MainActor
@Observable
final class PortActions {
  /// A port waiting for the user to choose variants before installing.
  struct InstallRequest: Identifiable {
    let name: String
    var id: String { name }
  }

  /// Set while the install-options sheet is showing.
  var installRequest: InstallRequest?
  /// Set while the uninstall confirmation is showing.
  var uninstallRequest: String?
  /// Set while the confirmation to activate an inactive version is showing.
  var activateRequest: InstalledPort?
  /// The port whose variants are being looked up before installing.
  private(set) var checkingVariants: String?

  let activity: ActivityLog
  private let runner: any PortCommandRunner
  private let afterCommand: () async -> Void

  /// `afterCommand` reloads whatever a command may have changed.
  init(
    activity: ActivityLog, runner: any PortCommandRunner = LivePortCommands(),
    afterCommand: @escaping () async -> Void
  ) {
    self.activity = activity
    self.runner = runner
    self.afterCommand = afterCommand
  }

  /// Whether a command is running for `name`.
  func isWorking(on name: String) -> Bool { activity.runningName == name }

  /// Whether a new command can start for `name` right now.
  func canStart(_ name: String) -> Bool { !activity.isRunning && checkingVariants != name }

  // MARK: Install

  /// Installs straight away when the port has no variants; otherwise asks
  /// which to use (if the lookup fails, the sheet shows why).
  func install(_ name: String) async {
    guard canStart(name) else { return }
    checkingVariants = name
    let found = try? await runner.variants(of: name)
    checkingVariants = nil
    if let found, found.isEmpty {
      await install(name, flags: [])
    } else {
      installRequest = InstallRequest(name: name)
    }
  }

  func install(_ name: String, flags: [String]) async {
    let runner = self.runner
    await run((["sudo port install", name] + flags).joined(separator: " "), name: name) { out in
      try await runner.install(name, variantFlags: flags, onOutput: out)
    }
  }

  // MARK: Upgrade

  func upgrade(_ name: String) async {
    let runner = self.runner
    await run("sudo port upgrade \(name)", name: name) { out in
      try await runner.upgrade(name, onOutput: out)
    }
  }

  func upgradeAll() async {
    let runner = self.runner
    await run("sudo port upgrade outdated", name: "outdated") { out in
      try await runner.upgradeAll(onOutput: out)
    }
  }

  // MARK: Uninstall

  /// Asks for confirmation; `confirmUninstall` does the work.
  func requestUninstall(_ name: String) {
    guard canStart(name) else { return }
    uninstallRequest = name
  }

  func confirmUninstall(_ name: String) async {
    uninstallRequest = nil
    let runner = self.runner
    await run("sudo port uninstall \(name)", name: name) { out in
      try await runner.uninstall(name, onOutput: out)
    }
  }

  /// Removes one specific installed version, such as an inactive one.
  func remove(_ port: InstalledPort) async {
    let runner = self.runner
    await run("sudo port uninstall \(port.name) \(port.versionSpec)", name: port.name) { out in
      try await runner.uninstall(port, onOutput: out)
    }
  }

  // MARK: Inactive versions

  /// Asks for confirmation, since activating replaces the active version;
  /// `confirmActivate` does the work.
  func requestActivate(_ port: InstalledPort) {
    guard canStart(port.name) else { return }
    activateRequest = port
  }

  func confirmActivate(_ port: InstalledPort) async {
    activateRequest = nil
    let runner = self.runner
    await run("sudo port activate \(port.name) \(port.versionSpec)", name: port.name) { out in
      try await runner.activate(port, onOutput: out)
    }
  }

  func removeAllInactive() async {
    let runner = self.runner
    await run("sudo port uninstall inactive", name: "inactive") { out in
      try await runner.uninstallInactive(onOutput: out)
    }
  }

  /// Runs one command and then reloads. Does nothing while another command
  /// is running.
  private func run(
    _ title: String, name: String,
    work: @escaping (@escaping @MainActor @Sendable (String) -> Void) async throws -> Void
  ) async {
    guard !activity.isRunning else { return }
    await activity.run(title, name: name, work: work)
    await afterCommand()
  }
}
