// PortRegistry.swift - Read-only access to the MacPorts registry database.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
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

  /// Bytes each installed version's files take up, keyed by
  /// `InstalledPort.id`. Inactive versions are measured where they are stored
  /// (their image). Sizes are logical file sizes (`st_size`); a file hard-linked
  /// several times within one version counts once, and symlinks and
  /// directories count nothing. Versions without files are absent.
  ///
  /// Stats every file the registry lists, so run it off the main thread.
  public func diskUsage() throws -> [String: Int64] {
    let rows = try withDatabase { db in
      try Self.query(
        db,
        "SELECT p.name, p.version, p.revision, p.variants, p.state, "
          + "COALESCE(NULLIF(f.actual_path, ''), f.path) FROM files f "
          + "JOIN ports p ON p.id = f.id WHERE p.state IN ('installed', 'imaged') "
          + "ORDER BY p.id"
      ) { statement in
        (
          port: InstalledPort(
            name: Self.text(statement, 0), version: Self.text(statement, 1),
            revision: Int(sqlite3_column_int64(statement, 2)),
            variants: Self.text(statement, 3).split(separator: "+").map(String.init),
            isActive: Self.text(statement, 4) == "installed"),
          path: Self.text(statement, 5)
        )
      }
    }
    struct FileID: Hashable {
      let device: dev_t
      let inode: ino_t
    }
    var totals: [String: Int64] = [:]
    var seen: Set<FileID> = []
    var current = ""
    for (port, path) in rows {
      if port.id != current {
        current = port.id
        seen.removeAll(keepingCapacity: true)
      }
      var info = stat()
      guard !path.isEmpty, lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
        seen.insert(FileID(device: info.st_dev, inode: info.st_ino)).inserted
      else { continue }
      totals[port.id, default: 0] += Int64(info.st_size)
    }
    return totals
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

  /// Names of installed ports that no other installed port depends on, so
  /// each can be uninstalled without affecting another port (what
  /// `port echo leaves` lists). Inactive versions count on both sides, as
  /// in `dependents(of:)`.
  public func leafPorts() throws -> Set<String> {
    try withDatabase { db in
      Set(
        try Self.query(
          db,
          "SELECT DISTINCT p.name FROM ports p WHERE p.state IN ('installed', 'imaged') "
            + "AND NOT EXISTS (SELECT 1 FROM dependencies d JOIN ports q ON q.id = d.id "
            + "WHERE d.name = p.name AND q.name <> p.name "
            + "AND q.state IN ('installed', 'imaged'))"
        ) { Self.text($0, 0) })
    }
  }

  /// Rows of `PRAGMA quick_check`: `["ok"]` for a healthy database.
  public func quickCheck() throws -> [String] {
    try withDatabase { db in
      try Self.query(db, "PRAGMA quick_check") { Self.text($0, 0) }
    }
  }

  /// MacPorts' RPM-style version ordering, which its `VERSION` collation
  /// uses. The indexes on `version` are sorted by it, so SQLite needs it
  /// to read or verify them.
  static func compareVersions(_ a: [UInt8], _ b: [UInt8]) -> Int {
    if a == b { return 0 }
    func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    func isAlpha(_ c: UInt8) -> Bool { (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A }
    func isAlnum(_ c: UInt8) -> Bool { isDigit(c) || isAlpha(c) }

    var i = 0
    var j = 0
    while i < a.count && j < b.count {
      while i < a.count && !isAlnum(a[i]) { i += 1 }
      while j < b.count && !isAlnum(b[j]) { j += 1 }
      if i >= a.count || j >= b.count { break }

      var endA = i
      var endB = j
      let numeric = isDigit(a[i])
      let kind = numeric ? isDigit : isAlpha
      while endA < a.count && kind(a[endA]) { endA += 1 }
      while endB < b.count && kind(b[endB]) { endB += 1 }
      if endB == j { return numeric ? 1 : -1 }

      var segA = a[i..<endA]
      var segB = b[j..<endB]
      if numeric {
        while segA.first == 0x30 { segA = segA.dropFirst() }
        while segB.first == 0x30 { segB = segB.dropFirst() }
        if segA.count != segB.count { return segA.count > segB.count ? 1 : -1 }
      }
      if segA.lexicographicallyPrecedes(segB) { return -1 }
      if segB.lexicographicallyPrecedes(segA) { return 1 }
      i = endA
      j = endB
    }
    if i >= a.count && j >= b.count { return 0 }
    if (i >= a.count && !isAlpha(b[j])) || (i < a.count && isAlpha(a[i])) { return -1 }
    return 1
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
    sqlite3_create_collation_v2(
      db, "VERSION", SQLITE_UTF8, nil,
      { _, lengthA, pointerA, lengthB, pointerB in
        let a = UnsafeRawBufferPointer(start: pointerA, count: Int(lengthA))
        let b = UnsafeRawBufferPointer(start: pointerB, count: Int(lengthB))
        return Int32(PortRegistry.compareVersions(Array(a), Array(b)))
      }, nil)
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
