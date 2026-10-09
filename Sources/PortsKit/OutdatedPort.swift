import Foundation

/// A port with a newer version available, from `port outdated`.
public struct OutdatedPort: Identifiable, Hashable, Sendable {
    public let name: String
    public let installedVersion: String
    public let availableVersion: String
    public var id: String { name }

    public init(name: String, installedVersion: String, availableVersion: String) {
        self.name = name
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
    }
}

public enum OutdatedParser {
    /// Parses lines such as `git    2.44.0_0 < 2.45.0_0`. Anything else is ignored.
    public static func parse(_ output: String) -> [OutdatedPort] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 4, parts[2] == "<" else { return nil }
            return OutdatedPort(name: String(parts[0]),
                                installedVersion: String(parts[1]),
                                availableVersion: String(parts[3]))
        }
    }
}
