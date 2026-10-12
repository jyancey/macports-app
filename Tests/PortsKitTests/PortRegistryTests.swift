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
    let schema = [
      "CREATE TABLE ports (id INTEGER PRIMARY KEY, name TEXT COLLATE NOCASE, epoch INTEGER, "
        + "version TEXT, revision INTEGER, variants TEXT, state TEXT)",
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
