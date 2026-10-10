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
}
