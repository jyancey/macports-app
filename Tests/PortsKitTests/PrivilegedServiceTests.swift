// PrivilegedServiceTests.swift - Tests for running commands the way the privileged helper does, with a fake port.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Synchronization
import Testing

@testable import PortsKit

/// Collects output from a command.
final class Collected: Sendable {
  private let text = Mutex("")
  var value: String { text.withLock { $0 } }
  func add(_ chunk: String) { text.withLock { $0 += chunk } }
}

@Suite(.timeLimit(.minutes(1))) struct PrivilegedServiceTests {
  let directory: URL
  let port: String

  /// A `port` that behaves by verb: sync prints, clean fails, selfupdate waits
  /// with a child that ignores SIGINT.
  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("service-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("port")
    try """
      #!/bin/sh
      echo "args: $*"
      case " $* " in
        *" sync "*) echo "line one"; echo "line two"; printf "no newline" ;;
        *" clean "*) echo "it failed" >&2; exit 3 ;;
        *" selfupdate "*)
          sleep 30 &
          echo $! > "\(directory.path)/child"
          echo started
          wait ;;
      esac
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    port = script.path
  }

  func service() -> PrivilegedService {
    PrivilegedService(trust: { path, _ in path }, graceSeconds: 0.3)
  }

  func command(_ verb: String, _ arguments: String...) -> PrivilegedCommand {
    PrivilegedCommand(verb: verb, arguments: arguments, portPath: port)
  }

  @Test func runsPortAndStreamsItsOutputByLine() async {
    let output = Collected()
    let result = await service().run(id: "1", command: command("sync")) { output.add($0) }
    #expect(result == PrivilegedResult(kind: .finished, status: 0))
    #expect(output.value == "args: -N sync\nline one\nline two\nno newline")
    try? FileManager.default.removeItem(at: directory)
  }

  @Test func reportsAFailingStatusAndItsErrorOutput() async {
    let output = Collected()
    let result = await service().run(id: "1", command: command("clean", "--all", "zlib")) {
      output.add($0)
    }
    #expect(result.kind == .finished)
    #expect(result.status == 3)
    #expect(output.value.contains("it failed"))
    try? FileManager.default.removeItem(at: directory)
  }

  @Test func refusesWithoutRunningAnythingWhenARequestIsNotAllowed() async {
    let output = Collected()
    let result = await service().run(id: "1", command: command("reclaim")) { output.add($0) }
    #expect(result.kind == .rejected)
    #expect(result.message.contains("reclaim"))
    #expect(output.value.isEmpty)
    try? FileManager.default.removeItem(at: directory)
  }

  @Test func refusesAPortThatIsNotTrusted() async {
    let strict = PrivilegedService(trust: { path, _ in
      throw ExecutableTrust.Failure.untrusted(path: path, reason: "test")
    })
    let output = Collected()
    let result = await strict.run(id: "1", command: command("sync")) { output.add($0) }
    #expect(result.kind == .rejected)
    #expect(output.value.isEmpty)
    try? FileManager.default.removeItem(at: directory)
  }

  @Test func refusesAnotherProtocolVersion() async {
    var old = command("sync")
    old.protocolVersion = HelperConstants.protocolVersion + 1
    #expect(await service().run(id: "1", command: old) { _ in }.kind == .versionMismatch)
    try? FileManager.default.removeItem(at: directory)
  }

  @Test func cancelStopsPortAndWhatItStarted() async throws {
    let service = service()
    let output = Collected()
    let run = Task {
      await service.run(id: "job", command: command("selfupdate")) { output.add($0) }
    }
    // Wait until the command is running and has started its child.
    let childFile = directory.appendingPathComponent("child")
    for _ in 0..<500 where !output.value.contains("started") {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(output.value.contains("started"))
    #expect(service.isBusy)
    let child = Int32(
      try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    #expect(kill(child, 0) == 0)

    service.cancel(id: "job")
    let result = await run.value
    #expect(result.kind == .cancelled)
    #expect(!service.isBusy)
    // The child ignores the interrupt, so it is the later terminate that ends it.
    var gone = false
    for _ in 0..<300 where !gone {
      gone = kill(child, 0) != 0
      if !gone { try await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(gone)
    try? FileManager.default.removeItem(at: directory)
  }

  @Test func cancellingAnUnknownIdDoesNothing() {
    service().cancel(id: "nothing")
    try? FileManager.default.removeItem(at: directory)
  }

  @Test func aSecondCommandWithTheSameIdIsRefused() async throws {
    let service = service()
    let output = Collected()
    let first = Task { await service.run(id: "same", command: command("selfupdate")) { output.add($0) } }
    for _ in 0..<500 where !output.value.contains("started") {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await service.run(id: "same", command: command("sync")) { _ in }.kind == .rejected)
    service.cancel(id: "same")
    _ = await first.value
    try? FileManager.default.removeItem(at: directory)
  }
}

@Suite struct SourcesWritingTests {
  /// `<root>/bin/port` and `<root>/etc/macports/sources.conf`.
  func makePrefix() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("sources-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("etc/macports"), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("bin/port"))
    try "old\n".write(
      to: root.appendingPathComponent("etc/macports/sources.conf"), atomically: true,
      encoding: .utf8)
    return root
  }

  let service = PrivilegedService(trust: { path, _ in path })
  let good = "rsync://rsync.macports.org/macports/release/tarballs/ports.tar.gz [default]\n"

  @Test func replacesSourcesConfAtTheStandardLocation() throws {
    let root = try makePrefix()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = service.writeSources(
      SourcesUpdate(contents: good, portPath: root.path + "/bin/port"))
    #expect(result.kind == .finished)
    let file = root.path + "/etc/macports/sources.conf"
    #expect(try String(contentsOfFile: file, encoding: .utf8) == good)
    let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
    #expect(mode == 0o644)
    // No staging file is left behind.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path + "/etc/macports")
    #expect(leftovers == ["sources.conf"])
  }

  @Test func leavesTheOldFileWhenTheNewOneIsNotAllowed() throws {
    let root = try makePrefix()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = service.writeSources(
      SourcesUpdate(contents: "sftp://bad\n", portPath: root.path + "/bin/port"))
    #expect(result.kind == .rejected)
    #expect(
      try String(contentsOfFile: root.path + "/etc/macports/sources.conf", encoding: .utf8)
        == "old\n")
  }

  @Test func refusesWhenThePortIsNotTrusted() throws {
    let root = try makePrefix()
    defer { try? FileManager.default.removeItem(at: root) }
    let strict = PrivilegedService(trust: { path, _ in
      throw ExecutableTrust.Failure.untrusted(path: path, reason: "test")
    })
    #expect(
      strict.writeSources(SourcesUpdate(contents: good, portPath: root.path + "/bin/port")).kind
        == .rejected)
  }

  @Test func refusesAnotherProtocolVersion() throws {
    let update = SourcesUpdate(contents: good, portPath: "/x", protocolVersion: 99)
    #expect(service.writeSources(update).kind == .versionMismatch)
  }
}
