// PortNameTests.swift - Tests for validating port names, paths, versions, and variant flags.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Testing

@testable import PortsKit

struct PortNameTests {
  @Test func acceptsRealPortNames() {
    for name in ["zlib", "p5.34-libwww-perl", "gcc14", "g++", "py312-numpy", "libstdc++"] {
      #expect(PortClient.isValidPortName(name))
    }
  }

  @Test func rejectsShellAndOptionSyntax() {
    for name in ["", "-f", "a b", "a;rm", "a\"b", "$(x)", "a'b", "a\\b"] {
      #expect(!PortClient.isValidPortName(name))
    }
  }
}

@Test func safePathsAreConservative() {
  #expect(PortClient.isSafePath("/var/folders/ab/T/ports-app-1-2/install.log"))
  #expect(!PortClient.isSafePath("/tmp/a b"))
  #expect(!PortClient.isSafePath("/tmp/a;rm"))
  #expect(!PortClient.isSafePath(""))
}

@Test func versionSpecsAreValidated() {
  #expect(PortClient.isValidVersionSpec("@1.2.3_0+universal+x11"))
  #expect(!PortClient.isValidVersionSpec("1.2"))
  #expect(!PortClient.isValidVersionSpec("@1 ; rm"))
  #expect(!PortClient.isValidVersionSpec("@$(x)"))
}

@Test func variantFlagValidation() {
  #expect(PortClient.isValidVariantFlag("+universal"))
  #expect(PortClient.isValidVariantFlag("-gpl2"))
  #expect(!PortClient.isValidVariantFlag("universal"))
  #expect(!PortClient.isValidVariantFlag("+x; rm"))
  #expect(!PortClient.isValidVariantFlag("+"))
}

@Test func versionArgumentsNameEachExactVersion() throws {
  let ports = [
    InstalledPort(name: "zlib", version: "1.3", revision: 1, variants: [], isActive: false),
    InstalledPort(
      name: "git", version: "2.45.0", revision: 0, variants: ["universal"], isActive: false),
  ]
  #expect(try PortClient.versionArguments(ports) == "zlib @1.3_1 git @2.45.0_0+universal")
}

@Test func versionArgumentsRejectShellSyntax() {
  let badName = InstalledPort(
    name: "a;rm", version: "1", revision: 0, variants: [], isActive: false)
  let badVersion = InstalledPort(
    name: "zlib", version: "1 $(x)", revision: 0, variants: [], isActive: false)
  #expect(throws: PortClientError.self) { try PortClient.versionArguments([badName]) }
  #expect(throws: PortClientError.self) { try PortClient.versionArguments([badVersion]) }
}

@Test func batchUpgradeRejectsInvalidNamesBeforeRunning() async throws {
  // A missing `port`, so anything that got as far as running would fail with
  // `.notInstalled` instead.
  let client = PortClient(executablePath: "/nonexistent/port", verbose: false)
  do {
    try await client.upgrade(["zlib", "a;rm"]) { _ in }
    Issue.record("expected the invalid name to be rejected")
  } catch PortClientError.invalidName(let name) {
    #expect(name == "a;rm")
  }
  // Nothing to upgrade, so nothing runs.
  try await client.upgrade([String]()) { _ in }
}
