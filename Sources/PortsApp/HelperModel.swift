// HelperModel.swift - Installs, approves and removes the privileged helper, and asks for Touch ID before each command.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import AppKit
import LocalAuthentication
import PortsKit
import Security
import ServiceManagement

/// The state of the privileged helper that runs `port` as root, and the
/// controls for it in Settings. App-wide: while the helper is enabled,
/// `PrivilegedBackends.shared` uses it, and commands that need root no longer
/// show the administrator password prompt.
@MainActor
@Observable
final class HelperModel {
  nonisolated static let confirmKey = "confirmPrivilegedActions"

  enum Status: Equatable {
    /// This build isn't signed by the developer, or isn't a bundled app, so
    /// macOS wouldn't let it install a helper (and the helper wouldn't trust it).
    case unsupported(String)
    case notInstalled
    /// Installed; waiting for the user to allow it in System Settings.
    case needsApproval
    case enabled
  }

  private(set) var status: Status = .notInstalled
  /// What went wrong the last time installing or removing failed.
  private(set) var failure: String?

  /// Reports the helper's registration; replaced in tests.
  @MainActor struct Registration {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () async throws -> Void
    var openSettings: () -> Void
    var isSignedByDeveloper: () -> Bool
  }

  private let registration: Registration
  private let backends: PrivilegedBackends

  init(
    registration: Registration = .live, backends: PrivilegedBackends = .shared,
    watchActivation: Bool = true
  ) {
    self.registration = registration
    self.backends = backends
    refresh()
    if watchActivation {
      // The user approves the helper in System Settings, then comes back.
      // The model lives as long as the app, so the observer is never removed.
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.refresh() }
      }
    }
  }

  /// Rereads the registration, and starts or stops using the helper to match.
  func refresh() {
    guard registration.isSignedByDeveloper() else {
      status = .unsupported(
        "This copy of MacPortsApp isn't signed by its developer, so it can't install the helper. "
          + "Commands that need administrator rights use the macOS password prompt.")
      backends.helper = nil
      return
    }
    switch registration.status() {
    case .enabled:
      status = .enabled
      backends.helper = XPCPrivilegedHelper(confirm: { reason in
        try await Self.confirm(reason: reason)
      })
    case .requiresApproval:
      status = .needsApproval
      backends.helper = nil
    case .notRegistered:
      status = .notInstalled
      backends.helper = nil
    case .notFound:
      status = .unsupported("The helper isn't part of this build of MacPortsApp.")
      backends.helper = nil
    @unknown default:
      status = .notInstalled
      backends.helper = nil
    }
  }

  /// Installs the helper. macOS then asks the user to allow it in System
  /// Settings → Login Items, which is opened here.
  func install() {
    failure = nil
    do {
      try registration.register()
    } catch {
      failure = error.localizedDescription
    }
    refresh()
    if status == .needsApproval { registration.openSettings() }
  }

  func openSettings() { registration.openSettings() }

  func remove() async {
    failure = nil
    do { try await registration.unregister() } catch { failure = error.localizedDescription }
    refresh()
  }

  /// Why commands recently used the password prompt, if the helper was set up.
  var lastProblem: String? { status == .enabled ? backends.lastProblem : nil }

  /// Asks for Touch ID, or the password where there is no Touch ID, before a
  /// command runs as root. The helper doesn't ask for a password, so this is
  /// what keeps each action a deliberate one. Does nothing when switched off,
  /// or when this Mac has no way to authenticate.
  nonisolated static func confirm(reason: String) async throws {
    guard UserDefaults.standard.object(forKey: confirmKey) as? Bool ?? true else { return }
    let context = LAContext()
    var unavailable: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
      return
    }
    do {
      try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    } catch let error as LAError
      where [.userCancel, .systemCancel, .appCancel].contains(error.code)
    {
      throw PortClientError.cancelled
    } catch {
      throw PortClientError.commandFailed(
        status: -1, stderr: "Authentication failed: \(error.localizedDescription)")
    }
  }
}

@MainActor extension HelperModel.Registration {
  static let live: HelperModel.Registration = {
    let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    return HelperModel.Registration(
      status: { service.status },
      register: { try service.register() },
      unregister: { try await service.unregister() },
      openSettings: { SMAppService.openSystemSettingsLoginItems() },
      isSignedByDeveloper: { Self.isSignedByDeveloper() })
  }()

  /// Whether this app is signed by the developer's team: the helper only
  /// accepts such an app, and macOS only lets such an app install it.
  static func isSignedByDeveloper() -> Bool {
    var code: SecCode?
    var requirement: SecRequirement?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString(HelperConstants.appRequirement as CFString, [], &requirement)
        == errSecSuccess,
      let requirement
    else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
  }
}
