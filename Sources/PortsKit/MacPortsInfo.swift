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
  public var installedCount: Int
  public var lastSync: Date?

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

extension PortClient {
  public func macPortsInfo() async throws -> MacPortsInfo {
    let version = MacPortsInfo.parseVersion(try await run(["version"]))
    let prefix = executableURL.deletingLastPathComponent().deletingLastPathComponent().path
    let confDir = prefix + "/etc/macports"
    let fm = FileManager.default
    func read(_ path: String) -> String {
      (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
    let conf = MacPortsInfo.parseConf(read(confDir + "/macports.conf"))
    let dataPath = conf["portdbpath"] ?? prefix + "/var/macports"
    let sourcesConf = conf["sources_conf"] ?? confDir + "/sources.conf"
    let sources = MacPortsInfo.parseSources(read(sourcesConf))
    let count = PortListParser.parseInstalled(try await run(["-q", "installed"])).count
    let sync =
      (try? fm.attributesOfItem(
        atPath: dataPath + "/sources/rsync.macports.org/macports/release/tarballs/PortIndex"))?[
        .modificationDate] as? Date
    return MacPortsInfo(
      version: version, executablePath: executableURL.path,
      prefix: conf["prefix"] ?? prefix, dataPath: dataPath,
      applicationsDir: conf["applications_dir"] ?? "/Applications/MacPorts",
      sources: sources, sourcesConfPath: sourcesConf, installedCount: count, lastSync: sync)
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

    let sqlitePath = "/usr/bin/sqlite3"
    guard fm.isExecutableFile(atPath: sqlitePath) else {
      return RegistryStatus(
        path: path, exists: exists, readable: readable,
        integrity: .unavailable("The system sqlite3 command is unavailable."))
    }

    do {
      let result = try await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = ["-readonly", path, "PRAGMA quick_check;"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
          status: process.terminationStatus,
          output: String(decoding: outputData, as: UTF8.self),
          error: String(decoding: errorData, as: UTF8.self)
        )
      }.value
      let integrity = RegistryStatus.parseIntegrityOutput(
        result.status == 0 ? result.output : result.error, status: result.status)
      return RegistryStatus(
        path: path, exists: exists, readable: readable, integrity: integrity)
    } catch {
      return RegistryStatus(
        path: path, exists: exists, readable: readable,
        integrity: .unavailable(error.localizedDescription))
    }
  }
}
