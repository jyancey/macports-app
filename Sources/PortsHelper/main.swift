// main.swift - The privileged helper: a launchd daemon that runs MacPortsApp's port commands as root.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import PortsKit
import Synchronization
import os

// launchd starts this on demand when the app connects to its Mach service, and
// it quits again when it has been idle for a while. It runs as root, so it does
// exactly three things: accepts connections only from MacPortsApp (checked by
// code signature), runs `port` with arguments it has checked itself, and replaces
// sources.conf with a list it has checked. See PrivilegedService.

let log = Logger(subsystem: HelperConstants.helperIdentifier, category: "helper")

/// Counts open connections and running commands, so an idle helper can quit.
final class Activity: Sendable {
  private struct State {
    var connections = 0
    var commands = 0
    var idleSince: Date? = Date()

    mutating func markIdleIfQuiet() {
      if connections <= 0 && commands <= 0 { idleSince = Date() }
    }
  }

  private let state = Mutex(State())

  func connectionOpened() { state.withLock { $0.connections += 1; $0.idleSince = nil } }
  func connectionClosed() { state.withLock { $0.connections -= 1; $0.markIdleIfQuiet() } }
  func commandStarted() { state.withLock { $0.commands += 1; $0.idleSince = nil } }
  func commandEnded() { state.withLock { $0.commands -= 1; $0.markIdleIfQuiet() } }

  /// True once nothing has been connected or running for `seconds`.
  func hasBeenIdle(for seconds: TimeInterval) -> Bool {
    state.withLock { state in
      guard let since = state.idleSince else { return false }
      return Date().timeIntervalSince(since) >= seconds
    }
  }
}

let activity = Activity()
let service = PrivilegedService()

/// The helper's end of one connection from the app.
final class Export: NSObject, PrivilegedHelperProtocol {
  /// Makes request ids unique per connection, so one connection can't cancel
  /// another's command by guessing its id.
  private let tag = UUID().uuidString

  private func scoped(_ id: String) -> String { "\(tag):\(id)" }

  func run(
    _ requestID: String, command: Data, output: any PrivilegedOutputProtocol,
    reply: @escaping @Sendable (Data) -> Void
  ) {
    let sink = Sink(output)
    let id = scoped(requestID)
    activity.commandStarted()
    Task {
      defer { activity.commandEnded() }
      let result: PrivilegedResult
      if let decoded = try? JSONDecoder().decode(PrivilegedCommand.self, from: command) {
        log.info("running \(decoded.summary, privacy: .public)")
        result = await service.run(id: id, command: decoded) { sink.send($0) }
        log.info("finished \(decoded.verb, privacy: .public): \(String(describing: result.kind), privacy: .public) \(result.status)")
      } else {
        result = PrivilegedResult(kind: .rejected, message: "The request couldn't be read.")
      }
      reply(Self.encode(result))
    }
  }

  func cancel(_ requestID: String) {
    service.cancel(id: scoped(requestID))
  }

  func writeSources(_ update: Data, reply: @escaping @Sendable (Data) -> Void) {
    let result: PrivilegedResult
    if let decoded = try? JSONDecoder().decode(SourcesUpdate.self, from: update) {
      log.info("writing sources.conf")
      result = service.writeSources(decoded)
    } else {
      result = PrivilegedResult(kind: .rejected, message: "The request couldn't be read.")
    }
    reply(Self.encode(result))
  }

  func protocolVersion(reply: @escaping @Sendable (Int) -> Void) {
    reply(HelperConstants.protocolVersion)
  }

  private static func encode(_ result: PrivilegedResult) -> Data {
    (try? JSONEncoder().encode(result)) ?? Data()
  }
}

/// The app's output receiver, which XPC lets us call from any thread.
final class Sink: @unchecked Sendable {
  private let output: any PrivilegedOutputProtocol
  init(_ output: any PrivilegedOutputProtocol) { self.output = output }
  func send(_ text: String) { output.receive(text) }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
  func listener(
    _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = PrivilegedXPC.interface()
    connection.exportedObject = Export()
    connection.invalidationHandler = { activity.connectionClosed() }
    activity.connectionOpened()
    connection.resume()
    return true
  }
}

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
// Only the genuine, team-signed MacPortsApp may connect.
listener.setConnectionCodeSigningRequirement(HelperConstants.appRequirement)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
log.info("helper started, protocol \(HelperConstants.protocolVersion)")

// Quit when idle; launchd starts the helper again on the next connection.
let idleCheck = DispatchSource.makeTimerSource(queue: .main)
idleCheck.schedule(deadline: .now() + 30, repeating: 30)
idleCheck.setEventHandler {
  if !service.isBusy, activity.hasBeenIdle(for: 90) {
    log.info("idle, quitting")
    exit(0)
  }
}
idleCheck.resume()

RunLoop.main.run()
