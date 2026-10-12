// SearchScope.swift - Search matching modes and ranking for available ports.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
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
    // Rank each name once, rather than twice per comparison (a "py" search
    // sorts over 11,000 names).
    let ranked = names.map { (rank: rank($0), name: $0) }
    return ranked.sorted { a, b in
      a.rank != b.rank
        ? a.rank < b.rank : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }.map(\.name)
  }
}
