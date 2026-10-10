import Foundation

/// One variant of a port, as listed by `port variants`.
public struct PortVariant: Identifiable, Hashable, Sendable {
  public let name: String
  public let summary: String
  /// Enabled by default (shown as `[+]` by MacPorts).
  public let isDefault: Bool
  public let requires: [String]
  public let conflicts: [String]

  public var id: String { name }

  public init(
    name: String, summary: String = "", isDefault: Bool = false,
    requires: [String] = [], conflicts: [String] = []
  ) {
    self.name = name
    self.summary = summary
    self.isDefault = isDefault
    self.requires = requires
    self.conflicts = conflicts
  }
}

public enum PortVariantParser {
  /// Parses `port variants <name>` output.
  ///
  /// ```
  /// ffmpeg has the variants:
  ///    darwinssl: Enable https support
  /// [+]gpl2: Enable GPL code
  ///    gpl3: Enable GPL code
  ///      * requires gpl2
  /// ```
  public static func parse(_ output: String) -> [PortVariant] {
    var variants: [PortVariant] = []
    var current: PortVariant?

    func flush() {
      if let current { variants.append(current) }
      current = nil
    }

    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasSuffix("has the variants:") || trimmed.hasPrefix("Warning") {
        continue
      }

      if trimmed.hasPrefix("*") {
        guard let existing = current else { continue }
        let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        let words = body.split(separator: " ").map(String.init)
        guard let kind = words.first else { continue }
        let names = Array(words.dropFirst().drop { $0 == "with" })
        switch kind {
        case "requires":
          current = PortVariant(
            name: existing.name, summary: existing.summary, isDefault: existing.isDefault,
            requires: existing.requires + names, conflicts: existing.conflicts)
        case "conflicts":
          current = PortVariant(
            name: existing.name, summary: existing.summary, isDefault: existing.isDefault,
            requires: existing.requires, conflicts: existing.conflicts + names)
        default: break
        }
        continue
      }

      flush()
      var rest = Substring(trimmed)
      var isDefault = false
      if rest.hasPrefix("[+]") {
        isDefault = true
        rest = rest.dropFirst(3)
      } else if rest.hasPrefix("[-]") {
        rest = rest.dropFirst(3)
      }
      guard let colon = rest.firstIndex(of: ":") else {
        // Variant without a description, e.g. "universal"
        let name = rest.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { current = PortVariant(name: name, isDefault: isDefault) }
        continue
      }
      let name = rest[..<colon].trimmingCharacters(in: .whitespaces)
      let summary = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if !name.isEmpty { current = PortVariant(name: name, summary: summary, isDefault: isDefault) }
    }
    flush()
    return variants
  }

  /// The command-line flags that turn the defaults into `selected`: `+x`
  /// for chosen non-defaults, `-x` for defaults that were switched off.
  public static func flags(selected: Set<String>, from variants: [PortVariant]) -> [String] {
    variants.compactMap { v in
      let on = selected.contains(v.name)
      if on && !v.isDefault { return "+" + v.name }
      if !on && v.isDefault { return "-" + v.name }
      return nil
    }
  }
}
