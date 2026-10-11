import Testing

@testable import PortsKit

struct SearchRankingTests {
  @Test func ranksExactThenPrefixThenContains() {
    let sorted = SearchRanking.sorted(
      ["gtree", "tree-sitter", "tree", "atree", "dirtree"], for: "tree")
    #expect(sorted == ["tree", "tree-sitter", "atree", "dirtree", "gtree"])
  }

  @Test func rankingIgnoresCase() {
    #expect(SearchRanking.sorted(["xTree", "Tree"], for: "tree") == ["Tree", "xTree"])
  }

  @Test func nonContiguousMatchesComeLast() {
    #expect(SearchRanking.sorted(["a", "tree"], for: "tree") == ["tree", "a"])
  }

  /// Ranking once per name must give exactly the order the per-comparison
  /// ranking gave.
  @Test func matchesTheOriginalOrderingOnManyNames() {
    func original(_ names: [String], for term: String) -> [String] {
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
    let stems = ["py", "Py", "numpy", "py3", "spy", "happy", "zlib", "pyobjc", "PY"]
    let names = (0..<3000).map { i in "\(stems[i % stems.count])\(i % 7 == 0 ? "" : "-\(i % 113)")"
    }
    for term in ["py", "PY", "zlib", "nothing"] {
      #expect(SearchRanking.sorted(names, for: term) == original(names, for: term))
    }
  }
}
