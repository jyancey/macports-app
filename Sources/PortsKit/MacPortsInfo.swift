import Foundation

/// Facts about the local MacPorts installation.
public struct MacPortsInfo: Sendable, Equatable {
    public var version: String
    public var executablePath: String
    public var prefix: String
    public var dataPath: String
    public var applicationsDir: String
    public var sources: [String]
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
            if parts.count == 2 { result[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) }
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

extension PortClient {
    public func macPortsInfo() async throws -> MacPortsInfo {
        let version = MacPortsInfo.parseVersion(try await run(["version"]))
        let prefix = executableURL.deletingLastPathComponent().deletingLastPathComponent().path
        let confDir = prefix + "/etc/macports"
        let fm = FileManager.default
        func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        let conf = MacPortsInfo.parseConf(read(confDir + "/macports.conf"))
        let dataPath = conf["portdbpath"] ?? prefix + "/var/macports"
        let sources = MacPortsInfo.parseSources(read(conf["sources_conf"] ?? confDir + "/sources.conf"))
        let count = PortListParser.parseInstalled(try await run(["-q", "installed"])).count
        let sync = (try? fm.attributesOfItem(atPath: dataPath + "/sources/rsync.macports.org/macports/release/tarballs/PortIndex"))?[.modificationDate] as? Date
        return MacPortsInfo(version: version, executablePath: executableURL.path,
                            prefix: conf["prefix"] ?? prefix, dataPath: dataPath,
                            applicationsDir: conf["applications_dir"] ?? "/Applications/MacPorts",
                            sources: sources, installedCount: count, lastSync: sync)
    }
}
