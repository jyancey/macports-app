// PrivilegedHelperProtocol.swift - The XPC interface between the app and its privileged helper.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation

/// What the helper offers the app. Requests and replies are JSON `Data`
/// (`PrivilegedCommand`, `SourcesUpdate`, `PrivilegedResult`), so the
/// checked, typed values are what crosses the connection.
@objc public protocol PrivilegedHelperProtocol {
  /// Runs a `port` command as root. Output arrives at `output` a line at a
  /// time; `reply` gets the `PrivilegedResult` when the command has ended.
  func run(
    _ requestID: String, command: Data, output: any PrivilegedOutputProtocol,
    reply: @escaping @Sendable (Data) -> Void)

  /// Stops the command started as `requestID`, and what it started.
  func cancel(_ requestID: String)

  /// Replaces sources.conf; `reply` gets a `PrivilegedResult`.
  func writeSources(_ update: Data, reply: @escaping @Sendable (Data) -> Void)

  /// The helper's protocol version, to tell an old helper from a current one.
  func protocolVersion(reply: @escaping @Sendable (Int) -> Void)
}

/// The app's end of a running command: where the helper sends its output.
@objc public protocol PrivilegedOutputProtocol {
  func receive(_ text: String)
}

public enum PrivilegedXPC {
  /// The interface with its object-valued argument described, for both ends.
  public static func interface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: (any PrivilegedHelperProtocol).self)
    interface.setInterface(
      NSXPCInterface(with: (any PrivilegedOutputProtocol).self),
      for: #selector(PrivilegedHelperProtocol.run(_:command:output:reply:)),
      argumentIndex: 2, ofReply: false)
    return interface
  }
}
