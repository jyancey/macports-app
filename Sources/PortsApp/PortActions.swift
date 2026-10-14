// PortActions.swift - Starts install, upgrade, uninstall, and activate commands through the Activity log.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import PortsKit
import SwiftUI

/// The `port` commands that change what is installed. Tests substitute a fake.
protocol PortCommandRunner: Sendable {
  func variants(of name: String) async throws -> [PortVariant]
  func install(
    _ name: String, variantFlags: [String],
    onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws
  func upgrade(_ names: [String], onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  func upgradeAll(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws
  func uninstall(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  func uninstall(
    _ ports: [InstalledPort], onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws
  func uninstallInactive(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws
  func activate(_ port: InstalledPort, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  func clean(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
}

/// Runs each command with a new `PortClient`, so a `port` path or verbose
/// setting changed in Settings applies to the next command.
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

  func upgrade(_ names: [String], onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  {
    try await PortClient().upgrade(names, onOutput: onOutput)
  }

  func upgradeAll(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
    try await PortClient().upgradeAll(onOutput: onOutput)
  }

  func uninstall(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  {
    try await PortClient().uninstall(name, onOutput: onOutput)
  }

  func uninstall(
    _ ports: [InstalledPort], onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    try await PortClient().uninstall(ports, onOutput: onOutput)
  }

  func uninstallInactive(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
    try await PortClient().uninstallInactive(onOutput: onOutput)
  }

  func activate(_ port: InstalledPort, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  {
    try await PortClient().activate(port, onOutput: onOutput)
  }

  func clean(_ name: String, onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  {
    try await PortClient().clean(name, onOutput: onOutput)
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
  /// Set while the confirmation to remove every inactive version is showing.
  var removeAllInactiveRequested = false
  /// The port whose variants are being looked up before installing.
  private(set) var checkingVariants: String?
  /// The ports the running command was started for.
  private(set) var workingNames: Set<String> = []

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

  /// Whether the running command was started for `name`.
  func isWorking(on name: String) -> Bool { workingNames.contains(name) }

  /// What the running command is doing to `name` ("Building…"), for the
  /// detail pane; `fallback` until its output says.
  func progressText(for name: String, fallback: String) -> String {
    switch activity.progress[name] {
    case .working(let phase): phase + "…"
    case .queued: "Waiting…"
    case .done, nil: fallback
    }
  }

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
    await run((["sudo port install", name] + flags).joined(separator: " "), names: [name]) { out in
      try await runner.install(name, variantFlags: flags, onOutput: out)
    }
  }

  // MARK: Upgrade

  func upgrade(_ name: String) async { await upgrade([name]) }

  /// Upgrades several ports in one command.
  func upgrade(_ names: [String]) async {
    guard !names.isEmpty else { return }
    let runner = self.runner
    await run("sudo port upgrade " + names.joined(separator: " "), names: names) { out in
      try await runner.upgrade(names, onOutput: out)
    }
  }

  func upgradeAll() async {
    let runner = self.runner
    await run("sudo port upgrade outdated", names: ["outdated"]) { out in
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
    await run("sudo port uninstall \(name)", names: [name]) { out in
      try await runner.uninstall(name, onOutput: out)
    }
  }

  /// Removes one specific installed version, such as an inactive one.
  func remove(_ port: InstalledPort) async { await remove([port]) }

  /// Removes several specific installed versions in one command.
  func remove(_ ports: [InstalledPort]) async {
    guard !ports.isEmpty else { return }
    let runner = self.runner
    let specs = ports.map { "\($0.name) \($0.versionSpec)" }.joined(separator: " ")
    await run("sudo port uninstall \(specs)", names: ports.map(\.name)) { out in
      try await runner.uninstall(ports, onOutput: out)
    }
  }

  // MARK: Clean

  /// Deletes the port's work directory and distfiles. Nothing installed is
  /// affected, so there is no confirmation.
  func clean(_ name: String) async {
    guard canStart(name) else { return }
    let runner = self.runner
    await run("sudo port clean --all \(name)", names: [name]) { out in
      try await runner.clean(name, onOutput: out)
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
    await run("sudo port activate \(port.name) \(port.versionSpec)", names: [port.name]) { out in
      try await runner.activate(port, onOutput: out)
    }
  }

  /// Asks for confirmation; `confirmRemoveAllInactive` does the work.
  func requestRemoveAllInactive() {
    guard !activity.isRunning else { return }
    removeAllInactiveRequested = true
  }

  func confirmRemoveAllInactive() async {
    removeAllInactiveRequested = false
    await removeAllInactive()
  }

  private func removeAllInactive() async {
    let runner = self.runner
    await run("sudo port uninstall inactive", names: ["inactive"]) { out in
      try await runner.uninstallInactive(onOutput: out)
    }
  }

  /// Runs one command and then reloads. Does nothing while another command
  /// is running.
  private func run(
    _ title: String, names: [String],
    work: @escaping (@escaping @MainActor @Sendable (String) -> Void) async throws -> Void
  ) async {
    guard !activity.isRunning else { return }
    workingNames = Set(names)
    await activity.run(title, name: names.joined(separator: " "), work: work)
    workingNames = []
    await afterCommand()
  }
}
