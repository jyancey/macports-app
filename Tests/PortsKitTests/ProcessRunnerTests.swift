// ProcessRunnerTests.swift - Tests for running `port` processes.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Testing

@testable import PortsKit

/// Exercises `PortClient.run` against small shell scripts standing in for `port`.
@Suite struct ProcessRunnerTests {
  /// A temporary directory holding one executable script.
  struct Script {
    let directory: URL
    let client: PortClient

    init(_ body: String) throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ports-app-tests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("port")
      try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      client = PortClient(executablePath: url.path, verbose: false)
    }

    func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    /// Waits for the script to write a pid to `name`.
    func pid(in name: String, timeout: Duration = .seconds(5)) async throws -> pid_t {
      let clock = ContinuousClock()
      let deadline = clock.now + timeout
      while clock.now < deadline {
        if let text = try? String(contentsOfFile: path(name), encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          return pid
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw CancellationError()
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
  }

  private static func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

  @Test func returnsStandardOutput() async throws {
    let script = try Script("echo \"$@\"")
    defer { script.remove() }
    #expect(try await script.client.run(["-q", "installed"]) == "-q installed\n")
  }

  @Test func failureReportsStatusAndStandardError() async throws {
    let script = try Script("echo oops >&2; exit 3")
    defer { script.remove() }
    do {
      _ = try await script.client.run([])
      Issue.record("expected the command to fail")
    } catch PortClientError.commandFailed(let status, let stderr) {
      #expect(status == 3)
      #expect(stderr == "oops\n")
    }
  }

  @Test func mergedStandardErrorIsReturned() async throws {
    let script = try Script("echo out; echo err >&2")
    defer { script.remove() }
    let output = try await script.client.run([], mergeStderr: true)
    #expect(output.contains("out\n") && output.contains("err\n"))
  }

  /// Filling the stderr pipe before writing stdout deadlocks a reader that only drains stdout.
  @Test(.timeLimit(.minutes(1))) func largeOutputOnBothStreamsDoesNotDeadlock() async throws {
    let script = try Script(
      "head -c 1000000 /dev/zero | tr '\\0' e >&2; head -c 1000000 /dev/zero | tr '\\0' o")
    defer { script.remove() }
    let output = try await script.client.run([])
    #expect(output.utf8.count == 1_000_000)
  }

  @Test func cancellationTerminatesTheProcess() async throws {
    let script = try Script("echo $$ > \"$(dirname \"$0\")/pid\"; exec sleep 10")
    defer { script.remove() }
    let clock = ContinuousClock()
    let task = Task { try await script.client.run(["-q", "info", "slow-port"]) }
    let pid = try await script.pid(in: "pid")
    let start = clock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(clock.now - start < .seconds(3))
    #expect(!Self.isRunning(pid))
  }

  @Test func alreadyCancelledTaskNeverLaunches() async throws {
    let script = try Script("touch \"$(dirname \"$0\")/launched\"")
    defer { script.remove() }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await script.client.run([])
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!FileManager.default.fileExists(atPath: script.path("launched")))
  }

  /// A child that outlives `port` keeps the output pipe open; cancelling must not wait for it.
  @Test func cancellationDoesNotWaitForOrphanedChildren() async throws {
    let script = try Script(
      "dir=\"$(dirname \"$0\")\"; sleep 10 & echo $! > \"$dir/child\"; echo $$ > \"$dir/pid\"; wait"
    )
    defer { script.remove() }
    let clock = ContinuousClock()
    let task = Task { try await script.client.run([]) }
    let pid = try await script.pid(in: "pid")
    let child = try await script.pid(in: "child")
    defer { kill(child, SIGKILL) }
    let start = clock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(clock.now - start < .seconds(3))
    #expect(!Self.isRunning(pid))
  }

  /// Waiting on a process must not hold one of Swift concurrency's shared threads, or a
  /// few slow `port` calls stall every other async task in the app.
  @Test(.timeLimit(.minutes(1))) func concurrentRunsDoNotExhaustTheThreadPool() async throws {
    let script = try Script("sleep 1")
    defer { script.remove() }
    let count = 2 * ProcessInfo.processInfo.activeProcessorCount
    let clock = ContinuousClock()
    let elapsed = try await clock.measure {
      try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<count { group.addTask { try await script.client.run([]) } }
        try await group.waitForAll()
      }
    }
    // Blocking two pool threads per run would need about four rounds (4 s). The
    // limit leaves room for the machine being busy with other tests.
    #expect(elapsed < .seconds(3.2))
  }
}
