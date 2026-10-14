// PortRegistryTests.swift - Tests for reading the MacPorts registry database.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import SQLite3
import Testing

@testable import PortsKit

@Suite struct PortRegistryTests {
  /// A throwaway registry with the tables MacPorts creates.
  private static func makeRegistry(_ statements: [String]) throws -> (PortRegistry, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("registry-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("registry.db").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    sqlite3_create_collation_v2(
      db, "VERSION", SQLITE_UTF8, nil,
      { _, lengthA, pointerA, lengthB, pointerB in
        let a = Array(UnsafeRawBufferPointer(start: pointerA, count: Int(lengthA)))
        let b = Array(UnsafeRawBufferPointer(start: pointerB, count: Int(lengthB)))
        return Int32(PortRegistry.compareVersions(a, b))
      }, nil)
    let schema = [
      "CREATE TABLE ports (id INTEGER PRIMARY KEY, name TEXT COLLATE NOCASE, epoch INTEGER, "
        + "version TEXT COLLATE VERSION, revision INTEGER, variants TEXT, state TEXT)",
      "CREATE TABLE files (id INTEGER, path TEXT, actual_path TEXT, active INTEGER, binary BOOL)",
      "CREATE TABLE dependencies (id INTEGER, name TEXT, variants TEXT)",
    ]
    for sql in schema + statements {
      #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
    }
    return (PortRegistry(path: path), directory)
  }

  @Test func readsInstalledPortsWithVariantsAndActiveState() throws {
    let (registry, directory) = try Self.makeRegistry([
      "INSERT INTO ports VALUES (1, 'zlib', 0, '1.3.1', 0, '', 'installed')",
      "INSERT INTO ports VALUES (2, 'Arpack', 0, '3.9.1', 1, '+gfortran+openblas', 'installed')",
      "INSERT INTO ports VALUES (3, 'curl', 0, '8.0', 0, '', 'imaged')",
      "INSERT INTO ports VALUES (4, 'curl', 0, '8.1', 2, '+ssl', 'installed')",
      "INSERT INTO ports VALUES (5, 'broken', 0, '1', 0, '', 'something-else')",
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let ports = try registry.installedPorts()
    #expect(ports.map(\.id) == ["Arpack@3.9.1_1+gfortran+openblas", "curl@8.0_0", "curl@8.1_2+ssl", "zlib@1.3.1_0"])
    #expect(ports.map(\.isActive) == [true, false, true, true])
    #expect(ports[0].variants == ["gfortran", "openblas"])
  }

  @Test func filesBelongToTheActiveVersionOnly() throws {
    let (registry, directory) = try Self.makeRegistry([
      "INSERT INTO ports VALUES (1, 'curl', 0, '8.0', 0, '', 'imaged')",
      "INSERT INTO ports VALUES (2, 'curl', 0, '8.1', 0, '', 'installed')",
      "INSERT INTO files VALUES (1, '/opt/local/bin/old', '/opt/local/bin/old', 0, 0)",
      "INSERT INTO files VALUES (2, '/opt/local/bin/curl', '/opt/local/bin/curl', 1, 0)",
      "INSERT INTO files VALUES (2, '/opt/local/bin/a b''c', '/opt/local/bin/a b''c', 1, 0)",
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try registry.files(of: "curl") == ["/opt/local/bin/a b'c", "/opt/local/bin/curl"])
    #expect(try registry.files(of: "CURL").count == 2)
    #expect(try registry.files(of: "missing").isEmpty)
    #expect(try registry.files(of: "curl' OR '1'='1").isEmpty)
  }

  @Test func dependentsAreDistinctAndSorted() throws {
    let (registry, directory) = try Self.makeRegistry([
      "INSERT INTO ports VALUES (1, 'zlib', 0, '1', 0, '', 'installed')",
      "INSERT INTO ports VALUES (2, 'curl', 0, '1', 0, '', 'installed')",
      "INSERT INTO ports VALUES (3, 'curl', 0, '2', 0, '', 'imaged')",
      "INSERT INTO ports VALUES (4, 'Cairo', 0, '1', 0, '', 'installed')",
      "INSERT INTO dependencies VALUES (2, 'zlib', '')",
      "INSERT INTO dependencies VALUES (3, 'zlib', '')",
      "INSERT INTO dependencies VALUES (4, 'zlib', '')",
      "INSERT INTO dependencies VALUES (4, 'curl', '')",
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try registry.dependents(of: "zlib") == ["Cairo", "curl"])
    #expect(try registry.dependents(of: "curl") == ["Cairo"])
    #expect(try registry.dependents(of: "Cairo").isEmpty)
  }

  @Test func missingOrCorruptDatabaseThrows() throws {
    let missing = PortRegistry(path: "/nonexistent/registry.db")
    #expect(throws: PortRegistryError.self) { try missing.installedPorts() }

    let (_, directory) = try Self.makeRegistry([])
    defer { try? FileManager.default.removeItem(at: directory) }
    let junk = directory.appendingPathComponent("junk.db")
    try Data("not a database, just some text".utf8).write(to: junk)
    #expect(throws: PortRegistryError.self) { try PortRegistry(path: junk.path).installedPorts() }
  }

  @Test func versionsCompareLikeMacPorts() {
    func cmp(_ a: String, _ b: String) -> Int {
      PortRegistry.compareVersions(Array(a.utf8), Array(b.utf8))
    }
    #expect(cmp("1.2", "1.10") < 0)
    #expect(cmp("1.10", "1.2") > 0)
    #expect(cmp("1.0", "1.0") == 0)
    #expect(cmp("1.0", "1_0") == 0)
    #expect(cmp("007", "7") == 0)
    #expect(cmp("1.0", "1.0.1") < 0)
    #expect(cmp("1.0a", "1.0") < 0)
    #expect(cmp("1.0b", "1.0a") > 0)
    #expect(cmp("1.0", "1.0rc1") > 0)
    #expect(cmp("2", "10") < 0)
    #expect(cmp("1.1", "1.a") > 0)
  }

  @Test func diskUsageSumsEachVersionsFiles() throws {
    let files = FileManager.default.temporaryDirectory
      .appendingPathComponent("usage-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: files) }
    func write(_ name: String, bytes: Int) throws -> String {
      let url = files.appendingPathComponent(name)
      try Data(count: bytes).write(to: url)
      return url.path
    }
    let a = try write("a", bytes: 1000)
    let b = try write("b", bytes: 234)
    let image = try write("image", bytes: 50)
    let hardLink = files.appendingPathComponent("a-link").path
    try FileManager.default.linkItem(atPath: a, toPath: hardLink)
    let symlink = files.appendingPathComponent("a-sym").path
    try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: a)
    let (registry, directory) = try Self.makeRegistry([
      "INSERT INTO ports VALUES (1, 'zlib', 0, '1.3', 0, '', 'installed')",
      "INSERT INTO ports VALUES (2, 'zlib', 0, '1.2', 0, '', 'imaged')",
      "INSERT INTO ports VALUES (3, 'empty', 0, '1', 0, '', 'installed')",
      "INSERT INTO ports VALUES (4, 'gone', 0, '1', 0, '', 'installed')",
      "INSERT INTO files VALUES (1, '\(a)', '\(a)', 1, 0)",
      "INSERT INTO files VALUES (1, '\(b)', '\(b)', 1, 0)",
      "INSERT INTO files VALUES (1, '\(hardLink)', '\(hardLink)', 1, 0)",
      "INSERT INTO files VALUES (1, '\(symlink)', '\(symlink)', 1, 0)",
      "INSERT INTO files VALUES (1, '\(files.path)', '\(files.path)', 1, 0)",
      "INSERT INTO files VALUES (2, '/opt/local/lib/old', '\(image)', 0, 0)",
      "INSERT INTO files VALUES (2, '\(a)', '', 0, 0)",
      "INSERT INTO files VALUES (4, '/nonexistent/file', '/nonexistent/file', 1, 0)",
    ])
    defer { try? FileManager.default.removeItem(at: directory) }
    let usage = try registry.diskUsage()
    #expect(usage["zlib@1.3_0"] == 1234)
    // The inactive version is measured at its image path, falling back to `path`.
    #expect(usage["zlib@1.2_0"] == 1050)
    #expect(usage["empty@1_0"] == nil)
    #expect(usage["gone@1_0"] == nil)
  }

  @Test func collationLetsSQLiteVerifyVersionIndexes() throws {
    let (registry, directory) = try Self.makeRegistry([
      "CREATE INDEX port_name ON ports(name, epoch, version, revision)",
      "INSERT INTO ports VALUES (1, 'a', 0, '1.10', 0, '', 'installed')",
      "INSERT INTO ports VALUES (2, 'a', 0, '1.2', 0, '', 'imaged')",
    ])
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try registry.quickCheck() == ["ok"])
  }

  @Test func integrityCheckPassesOnThisMachinesRegistry() async throws {
    let client = PortClient()
    guard client.isAvailable, client.registry != nil else { return }
    let status = await client.registryStatus()
    #expect(status.integrity == .valid)
  }

  /// The registry has to answer exactly what `port` does; compared on this machine's install.
  @Test(.timeLimit(.minutes(5))) func matchesPortCommandOnThisMachine() async throws {
    let client = PortClient()
    guard client.isAvailable, let registry = client.registry else { return }

    let fromRegistry = try registry.installedPorts()
    let fromCommand = try await client.installedPortsFromCommand()
    let byID = { (ports: [InstalledPort]) in ports.sorted { $0.id < $1.id }.map { "\($0.id) \($0.isActive)" } }
    #expect(byID(fromRegistry) == byID(fromCommand))

    for name in Set(fromCommand.map(\.name)).sorted().prefix(60) {
      #expect(
        try registry.files(of: name).sorted() == (try await client.contentsFromCommand(of: name)).sorted(),
        "files of \(name)")
      #expect(
        try registry.dependents(of: name)
          == (try await client.dependentsFromCommand(of: name)).sorted {
            $0.caseInsensitiveCompare($1) == .orderedAscending
          },
        "dependents of \(name)")
    }
  }
}
