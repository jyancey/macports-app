// PrivilegedProcess.swift - Runs one command in its own process group, streaming its output, and can stop all of it.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Synchronization

/// Runs a program without a shell, in a process group of its own so that
/// `cancel()` also stops what it started (compilers `port` launched). Output,
/// standard output and error together, is passed on a line at a time.
public final class PrivilegedProcess: Sendable {
  public enum Failure: LocalizedError {
    case couldNotStart(String)

    public var errorDescription: String? {
      switch self {
      case .couldNotStart(let reason): "The command couldn't be started: \(reason)"
      }
    }
  }

  private struct State {
    var pid: pid_t = 0
    var cancelRequested = false
    var exited = false
  }

  private let state = Mutex(State())

  /// How long after the interrupt a command that is still running is terminated.
  private let graceSeconds: Double

  public init(graceSeconds: Double = 5) {
    self.graceSeconds = graceSeconds
  }

  /// Interrupts the command and everything it started (SIGINT), and
  /// terminates what is still running a few seconds later. Safe to call
  /// before the command has started: it is stopped as soon as it does.
  public func cancel() {
    let pid = state.withLock { state -> pid_t in
      state.cancelRequested = true
      return state.pid
    }
    if pid > 0 { interrupt(pid) }
  }

  private func interrupt(_ pid: pid_t) {
    Self.signalGroup(pid, SIGINT)
    DispatchQueue.global().asyncAfter(deadline: .now() + graceSeconds) { [self] in
      if !state.withLock({ $0.exited }) { Self.signalGroup(pid, SIGTERM) }
    }
  }

  /// Terminates what is left of the group now, and kills it if it is still
  /// there after the grace period.
  private func terminateGroup(_ pid: pid_t) {
    Self.signalGroup(pid, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + graceSeconds) {
      Self.signalGroup(pid, SIGKILL)
    }
  }

  /// The command is its group's leader (`POSIX_SPAWN_SETPGROUP`), so its
  /// group id is its pid. Only the group is signalled, never a bare pid that
  /// could by now belong to another process.
  private static func signalGroup(_ pid: pid_t, _ signal: Int32) {
    kill(-pid, signal)
  }

  /// Runs `executable` and returns its exit status (128 plus the signal
  /// number if it was killed).
  public func run(
    executable: String, arguments: [String], environment: [String: String],
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> Int32 {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { throw Failure.couldNotStart(String(cString: strerror(errno))) }
    let (readEnd, writeEnd) = (fds[0], fds[1])

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
    posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
    posix_spawn_file_actions_addclose(&actions, readEnd)
    posix_spawn_file_actions_addclose(&actions, writeEnd)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Its own process group, and a clean signal state: a child inherits the
    // spawning thread's blocked signals and any ignored ones, which would
    // keep cancel's interrupt and terminate from reaching it.
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setsigdefault(&attributes, &allSignals)
    posix_spawnattr_setflags(
      &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    posix_spawnattr_setpgroup(&attributes, 0)

    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      argv.forEach { free($0) }
      envp.forEach { free($0) }
    }

    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
    close(writeEnd)
    guard status == 0 else {
      close(readEnd)
      throw Failure.couldNotStart(String(cString: strerror(status)))
    }
    let child = pid
    let cancelNow = state.withLock { state -> Bool in
      state.pid = child
      return state.cancelRequested
    }
    if cancelNow { interrupt(child) }

    async let drained: Void = withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        self.readLines(from: readEnd, onOutput: onOutput)
        continuation.resume()
      }
    }
    let raw: Int32 = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        var raw: Int32 = 0
        while waitpid(child, &raw, 0) < 0 && errno == EINTR {}
        let cancelled = self.state.withLock { state -> Bool in
          state.exited = true
          return state.cancelRequested
        }
        // `port` may be gone while what it started is not (a compiler that
        // ignored the interrupt): finish them off, still inside the group.
        if cancelled { self.terminateGroup(child) }
        continuation.resume(returning: raw)
      }
    }
    await drained
    // A signal ends the status word's low seven bits; otherwise the exit code
    // is in the next byte.
    return (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
  }

  /// Reads until the pipe closes, or until the command has exited and
  /// nothing more arrives (something it started may keep the pipe open).
  private func readLines(from descriptor: Int32, onOutput: @Sendable (String) -> Void) {
    defer { close(descriptor) }
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    var idleAfterExit = 0

    func flush(all: Bool) {
      let end: Data.Index?
      if all {
        end = pending.endIndex
      } else {
        end = pending.lastIndex(of: 0x0A).map { pending.index(after: $0) }
      }
      guard let end, end > pending.startIndex else { return }
      onOutput(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
      pending.removeSubrange(pending.startIndex..<end)
    }

    while true {
      var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&request, 1, 200)
      if ready > 0 {
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 {
          pending.append(buffer, count: count)
          flush(all: false)
          idleAfterExit = 0
          continue
        }
        if count == 0 || errno != EINTR { break }
      } else if ready == 0, state.withLock({ $0.exited }) {
        idleAfterExit += 1
        if idleAfterExit >= 3 { break }
      }
    }
    flush(all: true)
  }
}
