// DiagnoseLiveTests.swift - Tests that run `port diagnose` against the local MacPorts.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Testing

@testable import PortsKit

@Suite struct DiagnoseLiveTests {
  @Test(.timeLimit(.minutes(1))) func diagnoseReturns() async throws {
    let client = PortClient()
    guard client.isAvailable else { return }
    _ = try await client.diagnoseFindings()
  }
}
