// PrivilegedCommandTests.swift - Tests for what the privileged helper agrees to run.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Testing

@testable import PortsKit

@Suite struct PrivilegedCommandTests {
  func command(_ verb: String, _ arguments: String..., verbose: Bool = false) -> PrivilegedCommand {
    PrivilegedCommand(
      verb: verb, arguments: arguments, verbose: verbose, portPath: "/opt/local/bin/port")
  }

  func rejects(_ command: PrivilegedCommand) -> Bool {
    (try? command.portArguments()) == nil
  }

  @Test func buildsThePortArguments() throws {
    #expect(try command("install", "zlib", "+universal").portArguments()
      == ["-N", "install", "zlib", "+universal"])
    #expect(try command("sync", verbose: true).portArguments() == ["-N", "-v", "sync"])
  }

  @Test func installTakesAPortAndVariantFlags() {
    #expect(!rejects(command("install", "zlib")))
    #expect(!rejects(command("install", "git", "+universal", "-gpg2")))
    #expect(rejects(command("install")))
    #expect(rejects(command("install", "zlib", "universal")))
    #expect(rejects(command("install", "zlib", "--force")))
    #expect(rejects(command("install", "-f", "zlib")))
  }

  @Test func upgradeTakesPortsOrOutdated() {
    #expect(!rejects(command("upgrade", "zlib", "xz")))
    #expect(!rejects(command("upgrade", "outdated")))
    #expect(rejects(command("upgrade")))
    #expect(rejects(command("upgrade", "zlib;rm")))
    #expect(rejects(command("upgrade", "--enforce-variants")))
  }

  @Test func uninstallTakesPortsWithOptionalVersions() {
    #expect(!rejects(command("uninstall", "zlib")))
    #expect(!rejects(command("uninstall", "inactive")))
    #expect(!rejects(command("uninstall", "zlib", "@1.3_1+universal", "xz", "@5.4_0")))
    #expect(rejects(command("uninstall")))
    // A version needs a port in front of it, once.
    #expect(rejects(command("uninstall", "@1.3_1")))
    #expect(rejects(command("uninstall", "zlib", "@1.3_1", "@1.2_0")))
    #expect(rejects(command("uninstall", "zlib", "@1 ; rm")))
    #expect(rejects(command("uninstall", "-f", "zlib")))
  }

  @Test func activateTakesOnePortAndVersion() {
    #expect(!rejects(command("activate", "zlib", "@1.3_1")))
    #expect(rejects(command("activate", "zlib")))
    #expect(rejects(command("activate", "zlib", "1.3")))
    #expect(rejects(command("activate", "zlib", "@1.3", "xz")))
  }

  @Test func cleanOnlyAcceptsAllWithATarget() {
    #expect(!rejects(command("clean", "--all", "zlib")))
    #expect(!rejects(command("clean", "--all", "installed")))
    #expect(rejects(command("clean", "zlib")))
    #expect(rejects(command("clean", "--dist", "zlib")))
    #expect(rejects(command("clean", "--all")))
  }

  @Test func selectOnlyAcceptsSet() {
    #expect(!rejects(command("select", "--set", "python", "python312")))
    #expect(rejects(command("select", "python", "python312")))
    #expect(rejects(command("select", "--set", "python")))
    #expect(rejects(command("select", "--set", "py thon", "none")))
  }

  @Test func syncAndSelfupdateTakeNothing() {
    #expect(!rejects(command("sync")))
    #expect(!rejects(command("selfupdate")))
    #expect(rejects(command("sync", "--force")))
    #expect(rejects(command("selfupdate", "--nosync")))
  }

  @Test func otherVerbsAreRefused() {
    for verb in ["", "reclaim", "load", "-f", "install;rm", "dont-know", "INSTALL", "diagnose"] {
      #expect(rejects(command(verb)), "\(verb)")
    }
    #expect(throws: PrivilegedCommand.Invalid.unknownVerb("load")) {
      try command("load").portArguments()
    }
  }

  @Test func shellSyntaxAndHugeRequestsAreRefused() {
    for bad in ["$(id)", "a b", "a\nb", "`id`", "a|b", "a&b", "a>b", "~", "../x", "a'b", "a\"b"] {
      #expect(rejects(command("install", bad)), "\(bad)")
    }
    #expect(rejects(command("install", String(repeating: "a", count: 300))))
    let many = PrivilegedCommand(
      verb: "upgrade", arguments: Array(repeating: "zlib", count: 501), portPath: "/x")
    #expect(rejects(many))
  }

  @Test func summaryReadsLikeTheCommand() {
    #expect(command("install", "zlib", "+universal").summary == "sudo port install zlib +universal")
  }

  @Test func commandsSurviveTheTripOverXPC() throws {
    let original = command("uninstall", "zlib", "@1.3_1", verbose: true)
    let decoded = try JSONDecoder().decode(
      PrivilegedCommand.self, from: JSONEncoder().encode(original))
    #expect(decoded == original)
    #expect(decoded.protocolVersion == HelperConstants.protocolVersion)
  }

  @Test func signingRequirementsNameTheTeamAndIdentifier() {
    #expect(HelperConstants.helperRequirement.contains("io.indegree.MacPortsApp.helper"))
    #expect(HelperConstants.appRequirement.contains("identifier \"io.indegree.MacPortsApp\""))
    #expect(HelperConstants.appRequirement.contains("8Z24F9PX5J"))
    #expect(HelperConstants.helperRequirement.hasPrefix("anchor apple generic"))
  }
}

@Suite struct SourcesUpdateTests {
  func update(_ text: String) -> SourcesUpdate {
    SourcesUpdate(contents: text, portPath: "/opt/local/bin/port")
  }

  @Test func acceptsAListOfAllowedSources() {
    #expect(update("# sources\nrsync://rsync.macports.org/macports/release/tarballs/ports.tar.gz [default]\n").problem == nil)
    #expect(update("file:///Users/me/ports\nhttps://example.org/ports.tar.gz\n").problem == nil)
  }

  @Test func refusesEmptyOddOrHugeContents() {
    #expect(update("").problem != nil)
    #expect(update("# only a comment\n").problem != nil)
    #expect(update("sftp://example.org/ports\n").problem != nil)
    #expect(update("https://example.org/ports\0\n").problem != nil)
    #expect(update(String(repeating: "# x\n", count: 20_000) + "https://example.org/p\n").problem != nil)
  }
}
