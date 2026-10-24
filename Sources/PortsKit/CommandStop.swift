// CommandStop.swift - Lets the app stop a running privileged `port` command without another administrator prompt.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Synchronization

/// Lets the app stop a running privileged `port` command without another
/// administrator prompt. The root shell running the command watches for a
/// file in the command's private directory; creating it interrupts `port`
/// and everything it started (see `PortClient.stoppableCommand`).
///
/// Set `CommandStop.current` around a streaming command to make it stoppable.
public final class CommandStop: Sendable {
  @TaskLocal public static var current: CommandStop?

  private struct State {
    var file: URL?
    var cancel: (@Sendable () -> Void)?
    var requested = false
  }

  private let state = Mutex(State())

  public init() {}

  /// Whether `request()` has been called.
  public var isRequested: Bool { state.withLock { $0.requested } }

  /// Stops the command now, or as soon as it starts.
  public func request() {
    let (file, cancel) = state.withLock { state in
      state.requested = true
      return (state.file, state.cancel)
    }
    if let file { Self.touch(file) }
    cancel?()
  }

  /// Called by the running command with the file its shell watches.
  func register(_ file: URL) {
    let requested = state.withLock { state in
      state.file = file
      return state.requested
    }
    if requested { Self.touch(file) }
  }

  /// Called by a command running in the privileged helper, which is stopped
  /// by calling `cancel` rather than by a file.
  func registerCancel(_ cancel: @escaping @Sendable () -> Void) {
    let requested = state.withLock { state in
      state.cancel = cancel
      return state.requested
    }
    if requested { cancel() }
  }

  func unregister() {
    state.withLock { state in
      state.file = nil
      state.cancel = nil
    }
  }

  private static func touch(_ file: URL) {
    FileManager.default.createFile(atPath: file.path, contents: nil)
  }
}
