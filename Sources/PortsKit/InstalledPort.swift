import Foundation

/// One installed version of a MacPorts port, as reported by `port installed`.
public struct InstalledPort: Identifiable, Hashable, Sendable {
  public let name: String
  public let version: String
  public let revision: Int
  public let variants: [String]
  public let isActive: Bool

  public var id: String { "\(name)@\(version)_\(revision)\(variants.map { "+" + $0 }.joined())" }

  public init(name: String, version: String, revision: Int, variants: [String], isActive: Bool) {
    self.name = name
    self.version = version
    self.revision = revision
    self.variants = variants
    self.isActive = isActive
  }
}

public enum PortListParser {
  /// Parses the output of `port -q installed`.
  /// Lines look like `  name @1.2.3_0+variant1+variant2 (active)`.
  public static func parseInstalled(_ output: String) -> [InstalledPort] {
    output.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
  }

  static func parseLine(_ line: String) -> InstalledPort? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2, parts[1].hasPrefix("@") else { return nil }

    let name = String(parts[0])
    let spec = parts[1].dropFirst()
    let isActive = parts.dropFirst(2).contains("(active)")

    // Variants follow the first "+" (variant names never contain "+").
    let plusSplit = spec.split(separator: "+", omittingEmptySubsequences: true)
    guard let versionPart = plusSplit.first else { return nil }
    let variants = plusSplit.dropFirst().map(String.init)

    // Revision follows the last "_" in the version part.
    var version = String(versionPart)
    var revision = 0
    if let underscore = version.lastIndex(of: "_"),
      let rev = Int(version[version.index(after: underscore)...])
    {
      revision = rev
      version = String(version[..<underscore])
    }

    return InstalledPort(
      name: name, version: version, revision: revision,
      variants: variants, isActive: isActive)
  }
}
