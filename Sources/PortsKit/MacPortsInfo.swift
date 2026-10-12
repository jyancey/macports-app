// MacPortsInfo.swift - Represents information about the local MacPorts installation.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation

/// Facts about the local MacPorts installation.
public struct MacPortsInfo: Sendable, Equatable {
  public var version: String
  public var executablePath: String
  public var prefix: String
  public var dataPath: String
  public var applicationsDir: String
  public var sources: [String]
  public var sourcesConfPath: String
  public var lastSync: Date?

  /// The registry database MacPorts keeps in `dataPath`.
  public var registryPath: String { dataPath + "/registry/registry.db" }

  /// Parses `port version` output ("Version: 2.12.6").
  public static func parseVersion(_ output: String) -> String {
    for line in output.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: ":", maxSplits: 1)
      if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "Version" {
        return parts[1].trimmingCharacters(in: .whitespaces)
      }
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Parses `key value` lines of a MacPorts config file, ignoring comments.
  public static func parseConf(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
      if parts.count == 2 {
        result[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
      }
    }
    return result
  }

  /// Source URLs from sources.conf, with any `[flags]` removed.
  public static func parseSources(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
      .compactMap { $0.split(separator: " ").first.map(String.init) }
  }
}

public struct RegistryStatus: Sendable, Equatable {
  public enum Integrity: Sendable, Equatable {
    case valid
    case invalid(String)
    case unavailable(String)
  }

  public let path: String
  public let exists: Bool
  public let readable: Bool
  public let integrity: Integrity

  public init(path: String, exists: Bool, readable: Bool, integrity: Integrity) {
    self.path = path
    self.exists = exists
    self.readable = readable
    self.integrity = integrity
  }

  public var isHealthy: Bool {
    exists && readable && integrity == .valid
  }

  public static func parseIntegrityOutput(_ output: String, status: Int32) -> Integrity {
    let lines = output.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if status == 0, lines.count == 1, lines[0].lowercased() == "ok" {
      return .valid
    }
    let message = lines.joined(separator: "\n")
    return .invalid(message.isEmpty ? "SQLite integrity check failed." : message)
  }
}

extension MacPortsInfo {
  /// A source URL is written into sources.conf and a privileged shell
  /// command, so keep it conservative.
  public static func isValidSourceURL(_ url: String) -> Bool {
    let schemes = ["file:///", "rsync://", "https://", "http://", "ftp://"]
    guard schemes.contains(where: url.hasPrefix) else { return false }
    return url.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/:._-~+%@".contains($0)) }
  }

  /// Returns `text` with `url` added, or nil if it is already present.
  /// `file://` sources go first so they shadow remote ones; others go before
  /// the `[default]` source.
  public static func addingSource(_ url: String, to text: String) -> String? {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    guard !parseSources(text).contains(url) else { return nil }
    func isSource(_ l: String) -> Bool {
      let t = l.trimmingCharacters(in: .whitespaces)
      return !t.isEmpty && !t.hasPrefix("#")
    }
    let index: Int
    if url.hasPrefix("file://") {
      index = lines.firstIndex(where: isSource) ?? lines.count
    } else {
      index = lines.firstIndex(where: { isSource($0) && $0.contains("[default]") }) ?? lines.count
    }
    lines.insert(url, at: index)
    return lines.joined(separator: "\n") + "\n"
  }

  /// Returns `text` without the source `url`, or nil if it is not present or
  /// is the only source.
  public static func removingSource(_ url: String, from text: String) -> String? {
    let sources = parseSources(text)
    guard sources.contains(url), sources.count > 1 else { return nil }
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    lines.removeAll { line in
      let t = line.trimmingCharacters(in: .whitespaces)
      return !t.hasPrefix("#") && t.split(separator: " ").first.map(String.init) == url
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension MacPortsInfo {
  /// Where MacPorts keeps the ports tree for a source (as
  /// `macports::getsourcepath` does): a `file://` source is used in place, a
  /// tarball (snapshot) source is unpacked into a `ports` folder named after
  /// the tarball's directory, and any other URL is mirrored by host and path.
  public static func sourcePath(for url: String, dataPath: String) -> String {
    if url.hasPrefix("file://") { return String(url.dropFirst("file://".count)) }
    let parts = url.split(omittingEmptySubsequences: false) { $0 == ":" || $0 == "/" }
      .map(String.init)
    guard parts.count > 3 else { return dataPath + "/sources" }
    let isSnapshot =
      ["rsync", "http", "https", "ftp"].contains(parts[0])
      && [".tar.gz", ".tar.bz2", ".tar"].contains { url.hasSuffix($0) }
    let components =
      isSnapshot ? parts[3..<(parts.count - 1)] + ["ports"] : parts[3...] + []
    return ([dataPath, "sources"] + components.filter { !$0.isEmpty }).joined(separator: "/")
  }

  /// When any source's PortIndex was last rebuilt, which `port sync` and
  /// `port selfupdate` do; nil if none is found.
  static func lastSync(of sources: [String], dataPath: String) -> Date? {
    sources.compactMap { source in
      (try? FileManager.default.attributesOfItem(
        atPath: sourcePath(for: source, dataPath: dataPath) + "/PortIndex"))?[.modificationDate]
        as? Date
    }.max()
  }
}

extension PortClient {
  /// Runs `port version` once; everything else is read from the config files.
  public func macPortsInfo() async throws -> MacPortsInfo {
    let version = MacPortsInfo.parseVersion(try await run(["version"]))
    let conf = localConf()
    let sources = MacPortsInfo.parseSources(Self.read(conf.sourcesConfPath))
    return MacPortsInfo(
      version: version, executablePath: executableURL.path,
      prefix: conf.values["prefix"] ?? conf.prefix, dataPath: conf.dataPath,
      applicationsDir: conf.values["applications_dir"] ?? "/Applications/MacPorts",
      sources: sources, sourcesConfPath: conf.sourcesConfPath,
      lastSync: MacPortsInfo.lastSync(of: sources, dataPath: conf.dataPath))
  }

  /// MacPorts' data directory (`portdbpath`), read from macports.conf
  /// without running `port`.
  public func dataPath() -> String { localConf().dataPath }

  /// Checks the registry database in `dataPath()`.
  public func registryStatus() async -> RegistryStatus {
    await registryStatus(for: dataPath())
  }

  private func localConf() -> (
    values: [String: String], prefix: String, dataPath: String, sourcesConfPath: String
  ) {
    let prefix = executableURL.deletingLastPathComponent().deletingLastPathComponent().path
    let confDir = prefix + "/etc/macports"
    let values = MacPortsInfo.parseConf(Self.read(confDir + "/macports.conf"))
    return (
      values, prefix, values["portdbpath"] ?? prefix + "/var/macports",
      values["sources_conf"] ?? confDir + "/sources.conf"
    )
  }

  private static func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
  }

  public func registryStatus(for dataPath: String) async -> RegistryStatus {
    let path = dataPath + "/registry/registry.db"
    let fm = FileManager.default
    let exists = fm.fileExists(atPath: path)
    let readable = exists && fm.isReadableFile(atPath: path)
    guard exists, readable else {
      return RegistryStatus(
        path: path, exists: exists, readable: readable,
        integrity: .unavailable(
          exists ? "The registry database is not readable." : "The registry database is missing."))
    }

    do {
      let rows = try PortRegistry(path: path).quickCheck()
      return RegistryStatus(
        path: path, exists: exists, readable: readable,
        integrity: RegistryStatus.parseIntegrityOutput(rows.joined(separator: "\n"), status: 0))
    } catch {
      return RegistryStatus(
        path: path, exists: exists, readable: readable,
        integrity: .unavailable(error.localizedDescription))
    }
  }
}
