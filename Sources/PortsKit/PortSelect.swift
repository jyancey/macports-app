import Foundation

/// A `port select` group (e.g. clang) with the option currently selected
/// and all choices.
public struct PortSelectGroup: Identifiable, Hashable, Sendable {
  public let name: String
  public let selected: String
  public let options: [String]
  public var id: String { name }
  public var isSet: Bool { selected != "none" }

  public init(name: String, selected: String, options: [String]) {
    self.name = name
    self.selected = selected
    self.options = options
  }
}

public enum PortSelectParser {
  /// Parses `port select --summary`. The header and `====` rule are skipped.
  public static func parse(_ output: String) -> [PortSelectGroup] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
      let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      guard parts.count >= 3, parts[0] != "Name", !parts[0].hasPrefix("=") else { return nil }
      return PortSelectGroup(name: parts[0], selected: parts[1], options: Array(parts.dropFirst(2)))
    }
  }
}
