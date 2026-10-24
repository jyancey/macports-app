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
import os

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

  private static let log = Logger(subsystem: HelperConstants.appIdentifier, category: "helper")

  private(set) var status: Status = .notInstalled
  /// What went wrong the last time installing, removing or turning off
  /// confirmation failed.
  private(set) var failure: String?
  /// Whether each command run through the helper asks for Touch ID first. On
  /// by default; see `setConfirmsActions`.
  private(set) var confirmsActions: Bool

  /// Reports the helper's registration; replaced in tests.
  @MainActor struct Registration {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () async throws -> Void
    var openSettings: () -> Void
    var isSignedByDeveloper: () -> Bool
  }

  /// Asks for Touch ID or the password, throwing if the user doesn't pass;
  /// replaced in tests.
  typealias Authenticate = @Sendable (_ reason: String) async throws -> Void

  private let registration: Registration
  private let backends: PrivilegedBackends
  private let defaults: UserDefaults
  private let authenticate: Authenticate

  init(
    registration: Registration = .live, backends: PrivilegedBackends = .shared,
    defaults: UserDefaults = .standard,
    authenticate: @escaping Authenticate = { try await HelperModel.authenticate(reason: $0) },
    watchActivation: Bool = true
  ) {
    self.registration = registration
    self.backends = backends
    self.defaults = defaults
    self.authenticate = authenticate
    confirmsActions = defaults.object(forKey: Self.confirmKey) as? Bool ?? true
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
    let registered = registration.status()
    Self.log.info("helper registration status: \(registered.rawValue)")
    switch registered {
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
      // What macOS reports for a daemon that has never been registered, as
      // well as for one whose plist is missing; registering tells them apart.
      status = .notInstalled
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
    var registrationError: NSError?
    do {
      try registration.register()
    } catch {
      registrationError = error as NSError
    }
    refresh()
    // While it waits for approval, macOS registers the helper and still
    // throws "Operation not permitted" (SMAppServiceErrorDomain 1). That is
    // the normal way to ask for approval, not a failure.
    if let registrationError, status != .needsApproval, status != .enabled {
      Self.log.error(
        "registering the helper failed: \(registrationError.domain) \(registrationError.code): \(registrationError.localizedDescription)"
      )
      failure =
        "\(registrationError.localizedDescription) (\(registrationError.domain) \(registrationError.code))"
    }
    if status == .needsApproval { registration.openSettings() }
  }

  func openSettings() { registration.openSettings() }

  func remove() async {
    failure = nil
    do { try await registration.unregister() } catch { failure = error.localizedDescription }
    refresh()
  }

  /// Turns confirmation on at once, but off only once the user passes Touch ID
  /// or the password: without it, anything able to drive the app gets root
  /// without a prompt. If they cancel or fail, it stays on.
  func setConfirmsActions(_ on: Bool) async {
    guard on != confirmsActions else { return }
    if !on {
      do {
        try await authenticate("turn off confirmation for administrator actions")
      } catch PortClientError.cancelled {
        return
      } catch PortClientError.commandFailed(_, let message) {
        failure = message
        return
      } catch {
        failure = error.localizedDescription
        return
      }
    }
    failure = nil
    confirmsActions = on
    defaults.set(on, forKey: Self.confirmKey)
  }

  /// Why commands recently used the password prompt, if the helper was set up.
  var lastProblem: String? { status == .enabled ? backends.lastProblem : nil }

  /// Asks for Touch ID, or the password where there is no Touch ID, before a
  /// command runs as root. The helper doesn't ask for a password, so this is
  /// what keeps each action a deliberate one. Does nothing when switched off.
  nonisolated static func confirm(reason: String) async throws {
    try await confirm(
      reason: reason,
      enabled: UserDefaults.standard.object(forKey: confirmKey) as? Bool ?? true,
      unavailable: authenticationUnavailable(),
      authenticate: { try await authenticate(reason: $0) })
  }

  /// The decision behind `confirm`. When this Mac can't authenticate
  /// (`unavailable` says why), it throws `PrivilegedHelperUnavailable`, so the
  /// command goes through the macOS password prompt instead: nothing runs as
  /// root without the user confirming it.
  nonisolated static func confirm(
    reason: String, enabled: Bool, unavailable: String?, authenticate: Authenticate
  ) async throws {
    guard enabled else { return }
    if let unavailable { throw PrivilegedHelperUnavailable(unavailable) }
    try await authenticate(reason)
  }

  /// Why this Mac can't ask for Touch ID or the password, such as when no
  /// password is set or Touch ID is locked out; nil when it can.
  nonisolated static func authenticationUnavailable() -> String? {
    var error: NSError?
    guard !LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      return nil
    }
    let detail = error.map { " (\($0.localizedDescription))" } ?? ""
    return "this Mac can't ask for Touch ID or your password\(detail)"
  }

  /// Asks for Touch ID, or the password where there is no Touch ID. Throws
  /// `PortClientError.cancelled` if the user cancels, and `commandFailed` if
  /// they fail or this Mac has no way to authenticate.
  nonisolated static func authenticate(reason: String) async throws {
    if let unavailable = authenticationUnavailable() {
      throw PortClientError.commandFailed(
        status: -1, stderr: unavailable.prefix(1).uppercased() + unavailable.dropFirst() + ".")
    }
    let context = LAContext()
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
