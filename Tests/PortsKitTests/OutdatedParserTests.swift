// OutdatedParserTests.swift - Tests for parsing `port outdated` output.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Testing

@testable import PortsKit

struct OutdatedParserTests {
  @Test func parsesOutdatedLines() {
    let out = "git                            2.44.0_0 < 2.45.0_0\ncurl 8.0.0_1 < 8.0.0_2\n"
    #expect(
      OutdatedParser.parse(out) == [
        OutdatedPort(name: "git", installedVersion: "2.44.0_0", availableVersion: "2.45.0_0"),
        OutdatedPort(name: "curl", installedVersion: "8.0.0_1", availableVersion: "8.0.0_2"),
      ])
  }

  @Test func ignoresNoiseAndEmptyOutput() {
    #expect(OutdatedParser.parse("").isEmpty)
    #expect(OutdatedParser.parse("No installed ports are outdated.\n").isEmpty)
  }
}
