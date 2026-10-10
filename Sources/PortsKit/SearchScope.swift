import Foundation

/// How a search term is matched against available ports.
public enum SearchScope: String, CaseIterable, Identifiable, Sendable {
  case name = "Name"
  case nameAndDescription = "Name & Description"
  case exact = "Exact"
  case regex = "Regex"

  public var id: Self { self }

  /// Flags passed to `port search`.
  var flags: [String] {
    switch self {
    case .name: ["--name"]
    case .nameAndDescription: []
    case .exact: ["--name", "--exact"]
    case .regex: ["--name", "--regex"]
    }
  }
}

/// Orders results so exact name matches come first, then prefix matches,
/// then the rest.
public enum SearchRanking {
  public static func sorted(_ names: [String], for term: String) -> [String] {
    let t = term.lowercased()
    func rank(_ name: String) -> Int {
      let n = name.lowercased()
      if n == t { return 0 }
      if n.hasPrefix(t) { return 1 }
      if n.contains(t) { return 2 }
      return 3
    }
    return names.sorted {
      let (a, b) = (rank($0), rank($1))
      return a != b ? a < b : $0.localizedStandardCompare($1) == .orderedAscending
    }
  }
}
