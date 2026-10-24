// HelperModelTests.swift - Tests for installing, approving and using the privileged helper.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import PortsKit
import ServiceManagement
import Testing

@testable import MacPortsApp

@MainActor
@Suite(.serialized) struct HelperModelTests {
  /// A stand-in for macOS's registration of the helper.
  final class Registry {
    var status = SMAppService.Status.notRegistered
    var signed = true
    var registerFailure: (any Error)?
    var registered = 0
    var unregistered = 0
    var settingsOpened = 0
    /// What the status becomes once registered, as when the user must approve it.
    var afterRegister = SMAppService.Status.requiresApproval
    /// What the status becomes when registering throws, as macOS does while it waits for approval.
    var afterFailedRegister: SMAppService.Status?
  }

  struct Refused: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
  }

  /// A stand-in for Touch ID: records each prompt and answers with `outcome`.
  final class Authenticator: @unchecked Sendable {
    var reasons: [String] = []
    var outcome: (any Error)?
  }

  let registry = Registry()
  let backends = PrivilegedBackends()
  let defaults = UserDefaults(suiteName: "HelperModelTests-\(UUID().uuidString)")!
  let authenticator = Authenticator()

  func makeModel() -> HelperModel {
    let registry = registry
    let authenticator = authenticator
    return HelperModel(
      registration: HelperModel.Registration(
        status: { registry.status },
        register: {
          if let failure = registry.registerFailure {
            if let after = registry.afterFailedRegister { registry.status = after }
            throw failure
          }
          registry.registered += 1
          registry.status = registry.afterRegister
        },
        unregister: {
          registry.unregistered += 1
          registry.status = .notRegistered
        },
        openSettings: { registry.settingsOpened += 1 },
        isSignedByDeveloper: { registry.signed }),
      backends: backends, defaults: defaults,
      authenticate: { reason in
        authenticator.reasons.append(reason)
        if let outcome = authenticator.outcome { throw outcome }
      },
      watchActivation: false)
  }

  @Test func startsNotInstalledAndUsesNoHelper() {
    let model = makeModel()
    #expect(model.status == .notInstalled)
    #expect(backends.helper == nil)
  }

  @Test func anEnabledHelperIsUsedForCommands() {
    registry.status = .enabled
    let model = makeModel()
    #expect(model.status == .enabled)
    #expect(backends.helper != nil)
  }

  @Test func installingAsksForApprovalAndOpensSystemSettings() {
    let model = makeModel()
    model.install()
    #expect(registry.registered == 1)
    #expect(model.status == .needsApproval)
    #expect(registry.settingsOpened == 1)
    #expect(backends.helper == nil)
    #expect(model.failure == nil)
  }

  @Test func comingBackAfterApprovingEnablesTheHelper() {
    let model = makeModel()
    model.install()
    registry.status = .enabled
    model.refresh()
    #expect(model.status == .enabled)
    #expect(backends.helper != nil)
  }

  @Test func anApprovedInstallDoesNotOpenSettings() {
    registry.afterRegister = .enabled
    let model = makeModel()
    model.install()
    #expect(model.status == .enabled)
    #expect(registry.settingsOpened == 0)
  }

  @Test func aFailedInstallIsReported() {
    registry.registerFailure = Refused()
    let model = makeModel()
    model.install()
    #expect(model.failure?.hasPrefix("Operation not permitted (") == true)
    #expect(model.status == .notInstalled)
    #expect(registry.settingsOpened == 0)
  }

  @Test func removingStopsUsingTheHelper() async {
    registry.status = .enabled
    let model = makeModel()
    await model.remove()
    #expect(registry.unregistered == 1)
    #expect(model.status == .notInstalled)
    #expect(backends.helper == nil)
  }

  @Test func aBuildNotSignedByTheDeveloperCannotUseTheHelper() {
    registry.signed = false
    registry.status = .enabled
    let model = makeModel()
    guard case .unsupported = model.status else {
      Issue.record("expected unsupported, got \(model.status)")
      return
    }
    #expect(backends.helper == nil)
  }

  /// macOS says "not found" for a helper that was never registered, so it is offered.
  @Test func aHelperNeverRegisteredCanBeInstalled() {
    registry.status = .notFound
    let model = makeModel()
    #expect(model.status == .notInstalled)
    #expect(backends.helper == nil)
    model.install()
    #expect(registry.registered == 1)
    #expect(model.status == .needsApproval)
  }

  /// What macOS really does: it registers the helper and throws "Operation not
  /// permitted" (SMAppServiceErrorDomain 1) until the user allows it.
  @Test func notPermittedWhileWaitingForApprovalIsNotAFailure() {
    registry.status = .notFound
    registry.registerFailure = NSError(
      domain: "SMAppServiceErrorDomain", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
    registry.afterFailedRegister = .requiresApproval
    let model = makeModel()
    model.install()
    #expect(model.failure == nil)
    #expect(model.status == .needsApproval)
    #expect(registry.settingsOpened == 1)
  }

  @Test func aRealFailureShowsTheErrorDomainAndCode() {
    registry.status = .notFound
    registry.registerFailure = NSError(
      domain: "SMAppServiceErrorDomain", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
    let model = makeModel()
    model.install()
    #expect(model.failure == "Operation not permitted (SMAppServiceErrorDomain 1)")
    #expect(model.status == .notInstalled)
    #expect(registry.settingsOpened == 0)
  }

  @Test func theLastProblemShowsOnlyWhileTheHelperIsEnabled() {
    backends.lastProblem = "the helper is out of date"
    let model = makeModel()
    #expect(model.lastProblem == nil)
    registry.status = .enabled
    model.refresh()
    #expect(model.lastProblem == "the helper is out of date")
  }

  @Test func confirmationCanBeSwitchedOff() async throws {
    UserDefaults.standard.set(false, forKey: HelperModel.confirmKey)
    defer { UserDefaults.standard.removeObject(forKey: HelperModel.confirmKey) }
    // Returns at once, without asking for Touch ID.
    try await HelperModel.confirm(reason: "Run sudo port sync")
  }

  @Test func confirmationIsOnByDefault() {
    #expect(makeModel().confirmsActions)
  }

  @Test func turningConfirmationOffAsksForTouchIDFirst() async {
    let model = makeModel()
    await model.setConfirmsActions(false)
    #expect(authenticator.reasons == ["turn off confirmation for administrator actions"])
    #expect(!model.confirmsActions)
    #expect(defaults.object(forKey: HelperModel.confirmKey) as? Bool == false)
    #expect(model.failure == nil)
  }

  @Test func cancellingTouchIDLeavesConfirmationOn() async {
    authenticator.outcome = PortClientError.cancelled
    let model = makeModel()
    await model.setConfirmsActions(false)
    #expect(model.confirmsActions)
    #expect(defaults.object(forKey: HelperModel.confirmKey) == nil)
    #expect(model.failure == nil)
  }

  @Test func failingTouchIDLeavesConfirmationOnAndSaysWhy() async {
    authenticator.outcome = PortClientError.commandFailed(
      status: -1, stderr: "This Mac can't ask for Touch ID or your password.")
    let model = makeModel()
    await model.setConfirmsActions(false)
    #expect(model.confirmsActions)
    #expect(defaults.object(forKey: HelperModel.confirmKey) == nil)
    #expect(model.failure == "This Mac can't ask for Touch ID or your password.")
  }

  @Test func turningConfirmationBackOnNeedsNoPrompt() async {
    defaults.set(false, forKey: HelperModel.confirmKey)
    let model = makeModel()
    #expect(!model.confirmsActions)
    await model.setConfirmsActions(true)
    #expect(authenticator.reasons.isEmpty)
    #expect(model.confirmsActions)
    #expect(defaults.bool(forKey: HelperModel.confirmKey))
  }

  @Test func thisTestBuildIsNotSignedByTheDeveloper() {
    #expect(!HelperModel.Registration.isSignedByDeveloper())
  }
}
