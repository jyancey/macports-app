import Foundation
import Synchronization

/// What a finished child process produced.
struct ProcessOutput: Sendable {
  var status: Int32
  var stdout: Data
  var stderr: Data
}

/// Runs a child process without blocking Swift concurrency's shared threads:
/// output is collected by readability handlers and completion arrives through
/// the termination handler. Cancelling the calling task terminates the process.
final class ChildProcess: Sendable {
  private struct State {
    var process: Process?
    var continuation: CheckedContinuation<ProcessOutput, any Error>?
    var cancelled = false
    var exited = false
    var openPipes = 0
    var stdout = Data()
    var stderr = Data()
  }

  private let state = Mutex(State())

  /// Runs `url` with `arguments`. When `terminateOnCancel` is false, cancelling
  /// the calling task does not stop the process (used for privileged commands,
  /// where terminating `osascript` would leave the root shell running anyway).
  static func run(
    _ url: URL, arguments: [String], mergeStderr: Bool = false, terminateOnCancel: Bool = true
  ) async throws -> ProcessOutput {
    let child = ChildProcess()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        child.start(url, arguments: arguments, mergeStderr: mergeStderr, continuation)
      }
    } onCancel: {
      if terminateOnCancel { child.cancel() }
    }
  }

  private func start(
    _ url: URL, arguments: [String], mergeStderr: Bool,
    _ continuation: CheckedContinuation<ProcessOutput, any Error>
  ) {
    let process = Process()
    process.executableURL = url
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let out = Pipe()
    let err = mergeStderr ? out : Pipe()
    process.standardOutput = out
    process.standardError = err
    let readers = mergeStderr ? [out.fileHandleForReading] : [out, err].map(\.fileHandleForReading)
    for (index, reader) in readers.enumerated() {
      reader.readabilityHandler = { [self] handle in
        let data = handle.availableData
        if data.isEmpty {
          handle.readabilityHandler = nil
          finish { $0.openPipes -= 1 }
        } else {
          state.withLock {
            if index == 0 { $0.stdout.append(data) } else { $0.stderr.append(data) }
          }
        }
      }
    }
    process.terminationHandler = { [self] _ in finish { $0.exited = true } }

    // Launching under the lock means `cancel()` sees either no process (and
    // launch is skipped) or a running one it can terminate.
    let failure: (any Error)? = state.withLock { state in
      state.continuation = continuation
      if state.cancelled { return CancellationError() }
      do {
        try process.run()
      } catch {
        return error
      }
      state.process = process
      state.openPipes = readers.count
      return nil
    }
    if let failure {
      for reader in readers { reader.readabilityHandler = nil }
      let pending = state.withLock { state in
        defer { state.continuation = nil }
        return state.continuation
      }
      pending?.resume(throwing: failure)
    }
  }

  private func cancel() {
    finish { state in
      state.cancelled = true
      if !state.exited { state.process?.terminate() }
    }
  }

  /// Applies `update`, then resumes the caller once the process has exited and
  /// both pipes are drained, or as soon as it exits after a cancel (a child it
  /// left behind may hold the pipes open).
  private func finish(_ update: (inout State) -> Void) {
    let ready: (CheckedContinuation<ProcessOutput, any Error>, Result<ProcessOutput, any Error>)? =
      state.withLock { state in
        update(&state)
        guard state.exited, state.cancelled || state.openPipes == 0,
          let continuation = state.continuation, let process = state.process
        else { return nil }
        state.continuation = nil
        if state.cancelled { return (continuation, .failure(CancellationError())) }
        return (
          continuation,
          .success(
            ProcessOutput(
              status: process.terminationStatus, stdout: state.stdout, stderr: state.stderr))
        )
      }
    if let (continuation, result) = ready { continuation.resume(with: result) }
  }
}
