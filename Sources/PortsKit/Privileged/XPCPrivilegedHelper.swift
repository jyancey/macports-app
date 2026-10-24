// XPCPrivilegedHelper.swift - The app's connection to the privileged helper.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Synchronization

/// Runs privileged commands in the helper over XPC. Each command uses a new
/// connection, which is checked against the helper's code signature before
/// anything is sent.
public final class XPCPrivilegedHelper: PrivilegedHelper {
  /// Asked before each command, with a sentence describing it; throw to refuse.
  /// The app uses it to ask for Touch ID.
  public typealias Confirm = @Sendable (_ reason: String) async throws -> Void

  private let confirm: Confirm
  private let machServiceName: String
  private let requirement: String

  public init(
    confirm: @escaping Confirm = { _ in },
    machServiceName: String = HelperConstants.machServiceName,
    requirement: String = HelperConstants.helperRequirement
  ) {
    self.confirm = confirm
    self.machServiceName = machServiceName
    self.requirement = requirement
  }

  public func run(
    _ command: PrivilegedCommand,
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    try await confirm("Run \(command.summary)")

    let (lines, lineSink) = AsyncStream.makeStream(of: String.self)
    // Output is passed on in the order it arrived, one at a time.
    let forwarding = Task { for await text in lines { await onOutput(text) } }
    defer { lineSink.finish() }

    let id = UUID().uuidString
    let connection = makeConnection()
    defer { connection.invalidate() }
    let channel = Channel(connection)

    let result: PrivilegedResult
    do {
      let request = try JSONEncoder().encode(command)
      let receiver = OutputReceiver { lineSink.yield($0) }
      // A Stop pressed in the app cancels the command in the helper.
      let stop = CommandStop.current
      stop?.registerCancel { channel.cancel(id) }
      defer { stop?.unregister() }
      result = try await withTaskCancellationHandler {
        try await send(over: connection, receivedOutput: receiver) { proxy, reply in
          proxy.run(id, command: request, output: receiver, reply: reply)
        }
      } onCancel: {
        channel.cancel(id)
      }
    } catch let error as PrivilegedHelperUnavailable {
      lineSink.finish()
      await forwarding.value
      throw error
    }
    lineSink.finish()
    await forwarding.value
    try Self.check(result)
  }

  public func writeSources(_ contents: String, portPath: String) async throws {
    try await confirm("Change the MacPorts sources")
    let connection = makeConnection()
    defer { connection.invalidate() }
    let request = try JSONEncoder().encode(SourcesUpdate(contents: contents, portPath: portPath))
    let result = try await send(over: connection, receivedOutput: nil) { proxy, reply in
      proxy.writeSources(request, reply: reply)
    }
    try Self.check(result)
  }

  /// A finished command with a failing status, a cancel, or a refusal.
  private static func check(_ result: PrivilegedResult) throws {
    switch result.kind {
    case .finished:
      guard result.status == 0 else {
        throw PortClientError.commandFailed(status: result.status, stderr: result.message)
      }
    case .cancelled: throw PortClientError.cancelled
    case .rejected: throw PrivilegedHelperUnavailable(result.message)
    case .versionMismatch: throw PrivilegedHelperUnavailable(result.message)
    }
  }

  private func makeConnection() -> NSXPCConnection {
    let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
    connection.remoteObjectInterface = PrivilegedXPC.interface()
    connection.setCodeSigningRequirement(requirement)
    connection.resume()
    return connection
  }

  /// Sends one request and waits for its reply. A connection that can't be
  /// made (the helper isn't approved, or isn't signed by us) fails here as
  /// `PrivilegedHelperUnavailable`; one lost after the request went out is a
  /// failed command, since it may have run.
  private func send(
    over connection: NSXPCConnection, receivedOutput: OutputReceiver?,
    _ request: @escaping @Sendable (any PrivilegedHelperProtocol, @escaping @Sendable (Data) -> Void) -> Void
  ) async throws -> PrivilegedResult {
    try await withCheckedThrowingContinuation { continuation in
      let once = Once(continuation)
      let failed: @Sendable (any Error) -> Void = { error in
        let code = (error as NSError).code
        // 4099 invalid, 4101 signature requirement not met: never connected.
        // Anything else (4097 interrupted) may be after it started.
        let neverStarted =
          (error as NSError).domain == NSCocoaErrorDomain
          && [4099, 4101].contains(code) && !(receivedOutput?.hasReceived ?? false)
        once.resume(
          throwing: neverStarted
            ? PrivilegedHelperUnavailable("it can't be reached (\(error.localizedDescription))")
            : PortClientError.commandFailed(
              status: -1, stderr: "Lost the connection to the helper: \(error.localizedDescription)")
        )
      }
      connection.invalidationHandler = { failed(CocoaError(CocoaError.Code(rawValue: 4099))) }
      connection.interruptionHandler = { failed(CocoaError(CocoaError.Code(rawValue: 4097))) }
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler(failed)
          as? any PrivilegedHelperProtocol
      else {
        once.resume(throwing: PrivilegedHelperUnavailable("it can't be reached"))
        return
      }
      request(proxy) { data in
        do {
          once.resume(returning: try JSONDecoder().decode(PrivilegedResult.self, from: data))
        } catch {
          once.resume(throwing: PrivilegedHelperUnavailable("it sent an unreadable reply"))
        }
      }
    }
  }
}

/// The connection, for the callbacks that cancel a command from any thread
/// (an `NSXPCConnection` is safe to use that way).
private final class Channel: @unchecked Sendable {
  private let connection: NSXPCConnection

  init(_ connection: NSXPCConnection) { self.connection = connection }

  func cancel(_ id: String) {
    (connection.remoteObjectProxy as? any PrivilegedHelperProtocol)?.cancel(id)
  }
}

/// Resumes a continuation once, whichever of reply, error or invalidation comes first.
private final class Once<T: Sendable>: Sendable {
  private let continuation = Mutex<CheckedContinuation<T, any Error>?>(nil)

  init(_ continuation: CheckedContinuation<T, any Error>) {
    self.continuation.withLock { $0 = continuation }
  }

  func resume(returning value: T) { take()?.resume(returning: value) }
  func resume(throwing error: any Error) { take()?.resume(throwing: error) }

  private func take() -> CheckedContinuation<T, any Error>? {
    continuation.withLock { continuation in
      defer { continuation = nil }
      return continuation
    }
  }
}

/// Receives a command's output from the helper.
private final class OutputReceiver: NSObject, PrivilegedOutputProtocol, Sendable {
  private let sink: @Sendable (String) -> Void
  private let received = Mutex(false)

  init(sink: @escaping @Sendable (String) -> Void) { self.sink = sink }

  var hasReceived: Bool { received.withLock { $0 } }

  func receive(_ text: String) {
    received.withLock { $0 = true }
    sink(text)
  }
}
