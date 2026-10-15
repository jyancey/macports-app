// ExecutableTrustTests.swift - Tests for checking that a file run as root can't be changed by other users.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Testing

@testable import PortsKit

@Suite struct ExecutableTrustTests {
  let me: Set<uid_t> = [getuid()]

  /// `<root>/bin/port`, with the folders and file modes given.
  func makeTree(
    folderMode: Int = 0o755, fileMode: Int = 0o755
  ) throws -> (root: URL, port: String) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("trust-test-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(
      at: bin, withIntermediateDirectories: true,
      attributes: [.posixPermissions: folderMode])
    try FileManager.default.setAttributes([.posixPermissions: folderMode], ofItemAtPath: root.path)
    let port = bin.appendingPathComponent("port")
    try Data("#!/bin/sh\n".utf8).write(to: port)
    try FileManager.default.setAttributes([.posixPermissions: fileMode], ofItemAtPath: port.path)
    return (root, port.path)
  }

  @Test func acceptsAnExecutableOnlyItsOwnerCanChange() throws {
    let (root, port) = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try ExecutableTrust.validate(port, owners: me, below: root.path) == port)
  }

  @Test func refusesFilesOrFoldersOthersCanWrite() throws {
    let group = try makeTree(fileMode: 0o775)
    defer { try? FileManager.default.removeItem(at: group.root) }
    #expect(throws: ExecutableTrust.Failure.self) {
      try ExecutableTrust.validate(group.port, owners: me, below: group.root.path)
    }

    let folder = try makeTree(folderMode: 0o757)
    defer { try? FileManager.default.removeItem(at: folder.root) }
    #expect(throws: ExecutableTrust.Failure.self) {
      try ExecutableTrust.validate(folder.port, owners: me, below: folder.root.path)
    }
  }

  @Test func refusesAFolderAboveTheFileThatOthersCanWrite() throws {
    let (root, port) = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
    #expect(throws: ExecutableTrust.Failure.self) {
      try ExecutableTrust.validate(port, owners: me, below: root.path)
    }
  }

  @Test func refusesItemsOwnedByAnotherUser() throws {
    let (root, port) = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    // Only root is trusted by default, and these belong to the test's user.
    if getuid() != 0 {
      #expect(throws: ExecutableTrust.Failure.self) {
        try ExecutableTrust.validate(port, below: root.path)
      }
    }
  }

  @Test func refusesMissingRelativeAndNonExecutablePaths() throws {
    let (root, port) = try makeTree(fileMode: 0o644)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ExecutableTrust.Failure.notExecutable(port)) {
      try ExecutableTrust.validate(port, owners: me, below: root.path)
    }
    #expect(throws: ExecutableTrust.Failure.self) {
      try ExecutableTrust.validate(root.path + "/bin/nothing", owners: me, below: root.path)
    }
    #expect(throws: ExecutableTrust.Failure.notAbsolute("bin/port")) {
      try ExecutableTrust.validate("bin/port", owners: me, below: root.path)
    }
  }

  @Test func foldersPassWhenAnExecutableIsNotRequired() throws {
    let (root, _) = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(
      try ExecutableTrust.validate(
        root.path + "/bin", requireExecutable: false, owners: me, below: root.path)
        == root.path + "/bin")
  }

  /// The check runs on where a link leads, and that is what comes back to run.
  @Test func followsLinksAndChecksTheirTarget() throws {
    let (root, port) = try makeTree()
    let other = try makeTree(fileMode: 0o777)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: other.root)
    }
    let good = root.appendingPathComponent("bin/good").path
    try FileManager.default.createSymbolicLink(atPath: good, withDestinationPath: port)
    #expect(try ExecutableTrust.validate(good, owners: me, below: root.path) == port)

    let bad = root.appendingPathComponent("bin/bad").path
    try FileManager.default.createSymbolicLink(atPath: bad, withDestinationPath: other.port)
    #expect(throws: ExecutableTrust.Failure.self) {
      try ExecutableTrust.validate(bad, owners: me, below: root.path)
    }
  }
}
