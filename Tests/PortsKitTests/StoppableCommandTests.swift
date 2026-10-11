import Foundation
import Testing

@testable import PortsKit

/// Runs `PortClient.stoppableCommand` with `/bin/sh` (as `do shell script`
/// does, minus the root part) around a script standing in for `port`.
@Suite(.timeLimit(.minutes(1))) struct StoppableCommandTests {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ports-app-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

  /// Writes an executable script named "port" and returns the command that
  /// runs it, wrapped to be stoppable.
  func wrapped(_ body: String) throws -> String {
    let script = path("port")
    try ("#!/bin/sh\n" + body + "\n").write(toFile: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    return PortClient.stoppableCommand(script, log: path("log"), stopFile: path("stop"))
  }

  func run(_ command: String) async throws -> ProcessOutput {
    try await ChildProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command])
  }

  func pid(in name: String) async throws -> pid_t {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
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

  static func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

  @Test func passesOutputAndStatusThrough() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try await run(try wrapped("echo building; exit 3"))
    #expect(result.status == 3)
    #expect(try String(contentsOfFile: path("log"), encoding: .utf8) == "building\n")
  }

  /// `port` runs builds in the foreground and waits; stopping must reach that
  /// child too, not just `port`.
  @Test func stopInterruptsThePortAndWhatItStarted() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let command = try wrapped(
      "/bin/sh -c 'echo $$ > \(path("child.pid")); exec sleep 30'; echo not stopped")
    let stop = CommandStop()
    stop.register(URL(fileURLWithPath: path("stop")))
    let clock = ContinuousClock()
    let start = clock.now
    let running = Task { try await run(command) }
    let child = try await pid(in: "child.pid")
    #expect(Self.isRunning(child))

    stop.request()
    let result = try await running.value
    #expect(result.status != 0)
    #expect(clock.now - start < .seconds(4))
    #expect(!(try String(contentsOfFile: path("log"), encoding: .utf8)).contains("not stopped"))
    // The interrupted child goes away (it is reaped by launchd, so allow a moment).
    var gone = false
    for _ in 0..<100 where !gone {
      gone = !Self.isRunning(child)
      if !gone { try await Task.sleep(for: .milliseconds(20)) }
    }
    #expect(gone)
  }

  @Test func stopRequestedBeforeTheCommandStartsStillStopsIt() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let stop = CommandStop()
    stop.request()
    stop.register(URL(fileURLWithPath: path("stop")))
    #expect(FileManager.default.fileExists(atPath: path("stop")))
    let result = try await run(try wrapped("sleep 30"))
    #expect(result.status != 0)
  }

  @Test func aCommandThatIgnoresInterruptIsTerminated() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let command = try wrapped("trap '' INT; echo $$ > \(path("ready.pid")); sleep 30")
    let running = Task { try await run(command) }
    _ = try await pid(in: "ready.pid")
    FileManager.default.createFile(atPath: path("stop"), contents: nil)
    let clock = ContinuousClock()
    let start = clock.now
    let result = try await running.value
    #expect(result.status != 0)
    // Interrupt is ignored, so it ends with the terminate signal 5 s later.
    #expect(clock.now - start > .seconds(4))
    #expect(clock.now - start < .seconds(9))
  }
}
