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

  public init(
    name: String, version: String, revision: Int, categories: [String] = [],
    description: String = "", homepage: URL? = nil, license: String = "",
    maintainers: String = "", variants: [String] = [],
    libDependencies: [String] = [], buildDependencies: [String] = [],
    runDependencies: [String] = [], platforms: [String] = [],
    subports: [String] = []
  ) {
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
  /// `port info --line` prints requested fields tab-separated, always in
  /// this order regardless of the order the flags are given.
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

  /// Parses `port -q contents` (indented file paths) or
  /// `port -q dependents` (one name per line).
  /// Lines that aren't a single token (such as "x has no dependents!")
  /// are dropped.
  public static func parseFileList(_ output: String) -> [String] {
    output.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.contains(" has no ") }
  }

  /// Accepts bare names and the `name depends on other` lines newer `port` prints.
  public static func parseDependents(_ output: String) -> [String] {
    parseFileList(output).compactMap { line in
      let words = line.split(separator: " ")
      if words.count == 4, words[1] == "depends", words[2] == "on" { return String(words[0]) }
      return words.count == 1 ? line : nil
    }
  }

  /// A port in a dependency tree.
  public struct DependencyNode: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public var children: [DependencyNode]?

    public init(id: Int, name: String, children: [DependencyNode]? = nil) {
      self.id = id
      self.name = name
      self.children = children
    }
  }

  /// Parses `port -q rdeps` (two-space indentation per level) into a forest.
  public static func parseDependencyTree(_ output: String) -> [DependencyNode] {
    struct Entry {
      var name: String
      var depth: Int
    }
    var entries: [Entry] = []
    for line in output.split(whereSeparator: \.isNewline) {
      let name = line.trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, !name.contains(" ") else { continue }
      let indent = line.prefix { $0 == " " }.count
      entries.append(Entry(name: name, depth: max(indent / 2 - 1, 0)))
    }
    var nextID = 0
    func build(_ index: inout Int, depth: Int) -> [DependencyNode] {
      var nodes: [DependencyNode] = []
      while index < entries.count, entries[index].depth >= depth {
        guard entries[index].depth == depth else {
          index += 1
          continue
        }
        let entry = entries[index]
        index += 1
        let id = nextID
        nextID += 1
        let kids = build(&index, depth: depth + 1)
        nodes.append(DependencyNode(id: id, name: entry.name, children: kids.isEmpty ? nil : kids))
      }
      return nodes
    }
    var index = 0
    return build(&index, depth: 0)
  }

  /// One port name per line, de-duplicated and sorted.
  public static func parseNames(_ output: String) -> [String] {
    Array(Set(parseDependents(output))).sorted()
  }
}

/// The `port` queries behind the port detail pane. `PortClient` runs the real
/// commands; tests substitute their own.
public protocol PortDetailSource: Sendable {
  func info(for name: String) async throws -> PortInfo
  func contents(of name: String) async throws -> [String]
  func dependents(of name: String) async throws -> [String]
  func dependencyTree(of name: String) async throws -> [PortInfoParser.DependencyNode]
  func variants(of name: String) async throws -> [PortVariant]
}

extension PortClient: PortDetailSource {}

/// Runs each query with the `port` path configured at that moment, so a path
/// changed in Configuration applies to views that are already open.
public struct ConfiguredPortClient: PortDetailSource {
  public init() {}

  public func info(for name: String) async throws -> PortInfo {
    try await PortClient().info(for: name)
  }

  public func contents(of name: String) async throws -> [String] {
    try await PortClient().contents(of: name)
  }

  public func dependents(of name: String) async throws -> [String] {
    try await PortClient().dependents(of: name)
  }

  public func dependencyTree(of name: String) async throws -> [PortInfoParser.DependencyNode] {
    try await PortClient().dependencyTree(of: name)
  }

  public func variants(of name: String) async throws -> [PortVariant] {
    try await PortClient().variants(of: name)
  }
}
