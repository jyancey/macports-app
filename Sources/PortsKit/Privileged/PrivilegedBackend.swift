// PrivilegedBackend.swift - Runs privileged commands through the helper, and reports when it can't be used.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Synchronization

/// Why the helper couldn't take a request, so the app can fall back to the
/// administrator password prompt. Nothing was run.
public struct PrivilegedHelperUnavailable: LocalizedError {
  public let reason: String
  public init(_ reason: String) { self.reason = reason }
  public var errorDescription: String? { "The privileged helper isn't available: \(reason)" }
}

/// Something that can run `port` commands as root.
public protocol PrivilegedHelper: Sendable {
  /// Runs `command`, passing output a line at a time. Throws
  /// `PrivilegedHelperUnavailable` if nothing was run because the helper
  /// can't be reached or refused the request; any other error comes from the
  /// command itself.
  func run(
    _ command: PrivilegedCommand,
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws

  /// Replaces sources.conf under the prefix of `portPath`. Throws
  /// `PrivilegedHelperUnavailable` like `run`.
  func writeSources(_ contents: String, portPath: String) async throws
}

/// The helper the app uses for privileged commands, if there is one. The
/// app sets it when the helper is installed and approved; without it, commands
/// use the administrator password prompt.
public final class PrivilegedBackends: Sendable {
  public static let shared = PrivilegedBackends()

  private let current = Mutex<(any PrivilegedHelper)?>(nil)
  private let problem = Mutex<String?>(nil)

  public init() {}

  /// Why the helper couldn't take the most recent command, so it went through
  /// the password prompt instead; nil if the last one worked.
  public var lastProblem: String? {
    get { problem.withLock { $0 } }
    set { problem.withLock { $0 = newValue } }
  }

  public var helper: (any PrivilegedHelper)? {
    get { current.withLock { $0 } }
    set { current.withLock { $0 = newValue } }
  }
}
