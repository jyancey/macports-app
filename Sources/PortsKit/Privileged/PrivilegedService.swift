// PrivilegedService.swift - What the privileged helper does with a request: check it, then run port or write sources.conf.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Synchronization

/// The helper's logic, apart from the XPC plumbing so it can be tested. Every
/// request is checked here, whatever the caller claims: the verb and its
/// arguments against the allowed list, and `port` for being a file only root
/// can change.
public final class PrivilegedService: Sendable {
  /// Resolves and checks a path, an executable file or (when the flag is
  /// false) a folder, returning the real path.
  public typealias Trust = @Sendable (_ path: String, _ isExecutable: Bool) throws -> String

  private let trust: Trust
  private let graceSeconds: Double
  private let jobs = Mutex<[String: PrivilegedProcess]>([:])
  private let cancelled = Mutex<Set<String>>([])

  public init(
    trust: @escaping Trust = { try ExecutableTrust.validate($0, requireExecutable: $1) },
    graceSeconds: Double = 5
  ) {
    self.trust = trust
    self.graceSeconds = graceSeconds
  }

  /// Whether a command is running, so the helper doesn't quit under it.
  public var isBusy: Bool { jobs.withLock { !$0.isEmpty } }

  /// The environment for `port`: what a root shell from `do shell script` gave it.
  static let environment = [
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root", "TERM": "dumb",
    "LANG": "en_US.UTF-8",
  ]

  /// Runs `command` as `id`, passing output a line at a time to `onOutput`.
  public func run(
    id: String, command: PrivilegedCommand,
    onOutput: @escaping @Sendable (String) -> Void
  ) async -> PrivilegedResult {
    guard command.protocolVersion == HelperConstants.protocolVersion else {
      return PrivilegedResult(
        kind: .versionMismatch, message: "The helper is out of date. Reinstall it in Settings.")
    }
    let arguments: [String]
    let executable: String
    do {
      arguments = try command.portArguments()
      executable = try trust(command.portPath, true)
    } catch {
      return PrivilegedResult(kind: .rejected, message: error.localizedDescription)
    }

    let process = PrivilegedProcess(graceSeconds: graceSeconds)
    let started = jobs.withLock { jobs -> Bool in
      guard jobs[id] == nil else { return false }
      jobs[id] = process
      return true
    }
    guard started else {
      return PrivilegedResult(kind: .rejected, message: "A command with this id is running.")
    }
    defer { jobs.withLock { _ = $0.removeValue(forKey: id) } }
    // A cancel that arrived before the command was registered.
    if cancelled.withLock({ $0.remove(id) != nil }) { process.cancel() }

    do {
      let status = try await process.run(
        executable: executable, arguments: arguments, environment: Self.environment,
        onOutput: onOutput)
      let wasCancelled = cancelled.withLock { $0.remove(id) != nil }
      return PrivilegedResult(kind: wasCancelled ? .cancelled : .finished, status: status)
    } catch {
      return PrivilegedResult(kind: .rejected, message: error.localizedDescription)
    }
  }

  /// Stops the command `id` and what it started.
  public func cancel(id: String) {
    let process = jobs.withLock { $0[id] }
    if let process {
      cancelled.withLock { _ = $0.insert(id) }
      process.cancel()
    }
  }

  /// Replaces the prefix's sources.conf with `update.contents`, if it's a
  /// plain list of allowed sources. The file is written beside the old one
  /// and moved into place, so it is never half written.
  public func writeSources(_ update: SourcesUpdate) -> PrivilegedResult {
    guard update.protocolVersion == HelperConstants.protocolVersion else {
      return PrivilegedResult(
        kind: .versionMismatch, message: "The helper is out of date. Reinstall it in Settings.")
    }
    if let problem = update.problem { return PrivilegedResult(kind: .rejected, message: problem) }
    do {
      let port = try trust(update.portPath, true)
      // <prefix>/bin/port -> <prefix>/etc/macports/sources.conf
      let prefix = ((port as NSString).deletingLastPathComponent as NSString)
        .deletingLastPathComponent
      let folder = prefix + "/etc/macports"
      _ = try trust(folder, false)
      let target = folder + "/sources.conf"
      let staging = folder + "/.sources.conf.\(UUID().uuidString)"
      defer { try? FileManager.default.removeItem(atPath: staging) }
      guard
        FileManager.default.createFile(
          atPath: staging, contents: Data(update.contents.utf8),
          attributes: [.posixPermissions: 0o644])
      else {
        return PrivilegedResult(kind: .rejected, message: "Couldn't write \(target).")
      }
      guard rename(staging, target) == 0 else {
        return PrivilegedResult(
          kind: .rejected, message: "Couldn't replace \(target): \(String(cString: strerror(errno)))")
      }
      return PrivilegedResult(kind: .finished)
    } catch {
      return PrivilegedResult(kind: .rejected, message: error.localizedDescription)
    }
  }
}
