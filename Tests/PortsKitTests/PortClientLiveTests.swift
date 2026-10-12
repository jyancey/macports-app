// PortClientLiveTests.swift - Tests that run PortClient against the local MacPorts.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Testing

@testable import PortsKit

@Suite struct PortClientLiveTests {
  /// Matching `port` processes, found with pgrep.
  private static func processes(matching pattern: String) -> [String] {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", pattern]
    let out = Pipe()
    pgrep.standardOutput = out
    guard (try? pgrep.run()) != nil else { return [] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    pgrep.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isNewline).map(String.init)
  }

  /// `port rdeps` on a large port takes many seconds; cancelling must stop it.
  @Test(.timeLimit(.minutes(1))) func cancellingRdepsStopsPort() async throws {
    let client = PortClient()
    guard client.isAvailable else { return }
    // The full path keeps stand-in scripts from other tests from matching.
    let pattern = client.executableURL.path + " -q rdeps ffmpeg"
    let task = Task { try await client.dependencyTree(of: "ffmpeg") }
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while Self.processes(matching: pattern).isEmpty {
      // Finished (or failed) before it could be cancelled: nothing to check.
      guard clock.now < deadline else { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Self.processes(matching: pattern).isEmpty)
  }
}
