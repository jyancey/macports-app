import Foundation

/// Metadata for a port from `port info`.
public struct PortInfo: Hashable, Sendable {
    public var name: String
    public var version: String
    public var revision: Int
    public var categories: [String]
    public var description: String
    public var homepage: URL?
    public var license: String
    public var maintainers: String
    public var variants: [String]
    public var libDependencies: [String]
    public var buildDependencies: [String]
    public var runDependencies: [String]
    public var platforms: [String]
    public var subports: [String]

    public init(name: String, version: String, revision: Int, categories: [String] = [],
                description: String = "", homepage: URL? = nil, license: String = "",
                maintainers: String = "", variants: [String] = [],
                libDependencies: [String] = [], buildDependencies: [String] = [],
                runDependencies: [String] = [], platforms: [String] = [],
                subports: [String] = []) {
        self.name = name
        self.version = version
        self.revision = revision
        self.categories = categories
        self.description = description
        self.homepage = homepage
        self.license = license
        self.maintainers = maintainers
        self.variants = variants
        self.libDependencies = libDependencies
        self.buildDependencies = buildDependencies
        self.runDependencies = runDependencies
        self.platforms = platforms
        self.subports = subports
    }
}

public enum PortInfoParser {
    /// `port info --line` prints requested fields tab-separated, always in this order
    /// regardless of the order the flags are given.
    static let fieldFlags = [
        "--name", "--version", "--revision", "--categories", "--long_description",
        "--homepage", "--license", "--maintainers", "--variants", "--depends_lib",
        "--depends_build", "--depends_run", "--platforms", "--subports",
    ]

    public static func parse(_ output: String) -> PortInfo? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= fieldFlags.count, !f[0].isEmpty else { return nil }

        func list(_ s: String) -> [String] {
            s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return PortInfo(
            name: f[0], version: f[1], revision: Int(f[2]) ?? 0,
            categories: list(f[3]), description: f[4],
            homepage: URL(string: f[5]).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil },
            license: f[6], maintainers: f[7], variants: list(f[8]),
            libDependencies: list(f[9]), buildDependencies: list(f[10]),
            runDependencies: list(f[11]), platforms: list(f[12]), subports: list(f[13]))
    }

    /// Parses `port -q contents` (indented file paths) or `port -q dependents` (one name per line).
    /// Lines that aren't a single token (such as "x has no dependents!") are dropped.
    public static func parseFileList(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" has no ") }
    }

    public static func parseDependents(_ output: String) -> [String] {
        parseFileList(output).filter { !$0.contains(" ") }
    }
}
