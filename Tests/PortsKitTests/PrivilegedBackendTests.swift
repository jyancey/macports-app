// PrivilegedBackendTests.swift - Tests for PortClient running its privileged commands through the helper.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Synchronization
import Testing

@testable import PortsKit

/// Stands in for the helper: records what it was asked and answers as told.
final class FakeHelper: PrivilegedHelper, @unchecked Sendable {
  private let state = Mutex<(commands: [PrivilegedCommand], sources: [(String, String)])>(([], []))
  var failure: (any Error)?
  var output = ["--->  Fetching\n", "--->  Building\n"]

  var commands: [PrivilegedCommand] { state.withLock { $0.commands } }
  var sources: [(contents: String, portPath: String)] {
    state.withLock { $0.sources.map { (contents: $0.0, portPath: $0.1) } }
  }

  func run(
    _ command: PrivilegedCommand,
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    state.withLock { $0.commands.append(command) }
    if let failure { throw failure }
    for line in output { await onOutput(line) }
  }

  func writeSources(_ contents: String, portPath: String) async throws {
    state.withLock { $0.sources.append((contents, portPath)) }
    if let failure { throw failure }
  }
}

/// The app's one helper is global, so these run one at a time, and put it back.
@Suite(.serialized, .timeLimit(.minutes(1))) struct PrivilegedBackendTests {
  let helper = FakeHelper()
  let client: PortClient
  let prefix: FakePrefix

  init() throws {
    prefix = try FakePrefix(conf: "")
    client = PortClient(executablePath: prefix.root.path + "/bin/port", verbose: true)
    PrivilegedBackends.shared.helper = helper
  }

  func finish() {
    PrivilegedBackends.shared.helper = nil
    try? FileManager.default.removeItem(at: prefix.root)
  }

  final class Lines: Sendable {
    private let text = Mutex<[String]>([])
    var value: [String] { text.withLock { $0 } }
    func add(_ line: String) { text.withLock { $0.append(line) } }
  }

  @Test func installGoesToTheHelperWithItsOutput() async throws {
    defer { finish() }
    let lines = Lines()
    try await client.install("git", variantFlags: ["+universal"]) { lines.add($0) }
    #expect(
      helper.commands == [
        PrivilegedCommand(
          verb: "install", arguments: ["git", "+universal"], verbose: true,
          portPath: client.executableURL.path)
      ])
    #expect(lines.value == ["--->  Fetching\n", "--->  Building\n"])
  }

  @Test func everyKindOfCommandIsSentAsAVerbAndArguments() async throws {
    defer { finish() }
    let out: @MainActor @Sendable (String) -> Void = { _ in }
    try await client.upgrade(["zlib", "xz"], onOutput: out)
    try await client.upgradeAll(onOutput: out)
    try await client.uninstall("zlib", onOutput: out)
    try await client.uninstallInactive(onOutput: out)
    let port = InstalledPort(
      name: "zlib", version: "1.3", revision: 1, variants: ["universal"], isActive: false)
    try await client.uninstall([port], onOutput: out)
    try await client.activate(port, onOutput: out)
    try await client.clean("zlib", onOutput: out)
    try await client.cleanAll(onOutput: out)
    try await client.setSelection(group: "python", option: "python312", onOutput: out)
    try await client.selfupdate(onOutput: out)
    try await client.sync(onOutput: out)

    let sent = helper.commands.map { ($0.verb, $0.arguments) }
    let expected: [(String, [String])] = [
      ("upgrade", ["zlib", "xz"]), ("upgrade", ["outdated"]), ("uninstall", ["zlib"]),
      ("uninstall", ["inactive"]), ("uninstall", ["zlib", "@1.3_1+universal"]),
      ("activate", ["zlib", "@1.3_1+universal"]), ("clean", ["--all", "zlib"]),
      ("clean", ["--all", "installed"]), ("select", ["--set", "python", "python312"]),
      ("selfupdate", []), ("sync", []),
    ]
    #expect(sent.count == expected.count)
    for (got, want) in zip(sent, expected) {
      #expect(got.0 == want.0 && got.1 == want.1, "\(got) vs \(want)")
    }
    // Nothing the client sends is something the helper would refuse.
    for command in helper.commands { #expect(throws: Never.self) { try command.portArguments() } }
  }

  @Test func aFailingCommandIsAnErrorAndDoesNotFallBack() async {
    defer { finish() }
    helper.failure = PortClientError.commandFailed(status: 1, stderr: "nope")
    await #expect(throws: PortClientError.self) {
      try await client.install("zlib") { _ in }
    }
    #expect(helper.commands.count == 1)
  }

  @Test func cancellingInTheHelperIsCancelled() async {
    defer { finish() }
    helper.failure = PortClientError.cancelled
    do {
      try await client.sync { _ in }
      Issue.record("expected a cancel")
    } catch PortClientError.cancelled {
    } catch {
      Issue.record("unexpected \(error)")
    }
  }

  @Test func namesAreCheckedBeforeAnythingIsSent() async {
    defer { finish() }
    await #expect(throws: PortClientError.self) {
      try await client.install("a;rm -rf /") { _ in }
    }
    #expect(helper.commands.isEmpty)
  }

  @Test func sourcesAreWrittenByTheHelperAtTheStandardLocation() async throws {
    defer { finish() }
    let conf = prefix.root.path + "/etc/macports/sources.conf"
    #expect(client.standardSourcesConfPath == conf)
    try await client.addSource("https://example.org/ports.tar.gz", to: conf)
    #expect(helper.sources.count == 1)
    #expect(helper.sources[0].portPath == client.executableURL.path)
    #expect(helper.sources[0].contents.contains("https://example.org/ports.tar.gz"))
    #expect(helper.sources[0].contents.contains("rsync.macports.org"))
  }
}
