import Foundation
import SQLite3

public enum PortRegistryError: LocalizedError {
  case unavailable(String)
  case queryFailed(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): return "The MacPorts registry can't be opened: \(message)"
    case .queryFailed(let message): return "The MacPorts registry query failed: \(message)"
    }
  }
}

/// Read-only access to the MacPorts registry database. Answers the questions
/// `port installed`, `port contents` and `port dependents` answer, in
/// milliseconds instead of starting a Tcl interpreter for each one.
///
/// Each call opens its own short-lived connection, so the type is trivially
/// `Sendable` and never holds a lock on a database that MacPorts writes to.
public struct PortRegistry: Sendable {
  public let path: String

  public init(path: String) {
    self.path = path
  }

  /// A port is active when its registry state is `installed`; inactive
  /// versions are `imaged`.
  public func installedPorts() throws -> [InstalledPort] {
    try withDatabase { db in
      try Self.query(
        db,
        "SELECT name, version, revision, variants, state FROM ports "
          + "WHERE state IN ('installed', 'imaged') ORDER BY name COLLATE NOCASE, id"
      ) { statement in
        InstalledPort(
          name: Self.text(statement, 0), version: Self.text(statement, 1),
          revision: Int(sqlite3_column_int64(statement, 2)),
          variants: Self.text(statement, 3).split(separator: "+").map(String.init),
          isActive: Self.text(statement, 4) == "installed")
      }
    }
  }

  /// Files of the port's active version, or of its installed version when
  /// none is active.
  public func files(of name: String) throws -> [String] {
    try withDatabase { db in
      try Self.query(
        db,
        "SELECT f.path FROM files f JOIN ports p ON p.id = f.id "
          + "WHERE p.name = ?1 AND p.state = 'installed' ORDER BY f.path",
        bind: name
      ) { Self.text($0, 0) }
    }
  }

  /// Installed ports that depend directly on `name`.
  public func dependents(of name: String) throws -> [String] {
    try withDatabase { db in
      try Self.query(
        db,
        "SELECT DISTINCT p.name FROM ports p JOIN dependencies d ON d.id = p.id "
          + "WHERE d.name = ?1 AND p.state IN ('installed', 'imaged') "
          + "ORDER BY p.name COLLATE NOCASE",
        bind: name
      ) { Self.text($0, 0) }
    }
  }

  private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    var handle: OpaquePointer?
    let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
    defer { sqlite3_close(handle) }
    guard status == SQLITE_OK, let db = handle else {
      throw PortRegistryError.unavailable(
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(status)")
    }
    sqlite3_busy_timeout(db, 2000)
    return try body(db)
  }

  private static func query<T>(
    _ db: OpaquePointer, _ sql: String, bind: String? = nil,
    row: (OpaquePointer) -> T
  ) throws -> [T] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw PortRegistryError.queryFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    if let bind {
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      sqlite3_bind_text(statement, 1, bind, -1, transient)
    }
    var rows: [T] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: rows.append(row(statement))
      case SQLITE_DONE: return rows
      default: throw PortRegistryError.queryFailed(String(cString: sqlite3_errmsg(db)))
      }
    }
  }

  private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
  }
}
