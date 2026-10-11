import PortsKit
import Testing

@testable import MacPortsApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SearchModelTests {
  struct Failure: Error {}

  let gates = Gates()

  /// Searching for `term` returns `[term, term + "-extra"]`. Terms in `late`
  /// ignore cancellation, like a query that was already finishing; terms in
  /// `failing` throw once their gate opens.
  func makeModel(late: Set<String> = [], failing: Set<String> = []) -> SearchModel {
    let gates = gates
    return SearchModel(
      search: { term, _ in
        if late.contains(term) {
          await gates.passIgnoringCancellation("search \(term)")
        } else {
          try await gates.pass("search \(term)")
        }
        if failing.contains(term) { throw Failure() }
        return [term, term + "-extra"]
      },
      binaryHint: { name in
        try? await gates.pass("binary \(name)")
        return .available
      })
  }

  func isDone(_ model: SearchModel) -> Bool { model.hasSearched && !model.isSearching }

  @Test func showsResultsAndChecksBinaries() async throws {
    let model = makeModel()
    await gates.open("search zlib", "binary zlib", "binary zlib-extra")
    model.search("zlib", scope: .name)
    #expect(try await until { isDone(model) })
    #expect(model.results == ["zlib", "zlib-extra"])
    #expect(model.searchedTerm == "zlib")
    #expect(model.errorMessage == nil)
    #expect(try await until { model.binary == ["zlib": .available, "zlib-extra": .available] })
  }

  @Test func newSearchCancelsTheOneStillRunning() async throws {
    let model = makeModel()
    model.search("py", scope: .name)
    #expect(try await gates.waitForCall("search py"))
    model.search("zlib", scope: .name)
    await gates.open("search zlib")
    #expect(try await until { isDone(model) })
    #expect(model.results == ["zlib", "zlib-extra"])
    #expect(model.errorMessage == nil)
    #expect(try await gates.waitForCancellation("search py"))
  }

  /// The race this guards against: the older, slower search finishes after the
  /// newer one and would otherwise replace its results.
  @Test func olderResultsArrivingLateAreIgnored() async throws {
    let model = makeModel(late: ["py"])
    model.search("py", scope: .name)
    #expect(try await gates.waitForCall("search py"))
    model.search("zlib", scope: .name)
    await gates.open("search zlib")
    #expect(try await until { isDone(model) })

    await gates.open("search py")
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.results == ["zlib", "zlib-extra"])
    #expect(await !gates.calls.contains("binary py"))
  }

  @Test func olderFailureArrivingLateIsIgnored() async throws {
    let model = makeModel(late: ["py"], failing: ["py"])
    model.search("py", scope: .name)
    #expect(try await gates.waitForCall("search py"))
    model.search("zlib", scope: .name)
    await gates.open("search zlib")
    #expect(try await until { isDone(model) })

    await gates.open("search py")
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.errorMessage == nil)
    #expect(model.results == ["zlib", "zlib-extra"])
  }

  /// A replaced search must not clear the spinner while the newer one runs.
  @Test func staysBusyUntilTheNewestSearchFinishes() async throws {
    let model = makeModel(late: ["py"])
    model.search("py", scope: .name)
    #expect(try await gates.waitForCall("search py"))
    model.search("zlib", scope: .name)
    #expect(try await gates.waitForCall("search zlib"))

    await gates.open("search py")
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.isSearching)

    await gates.open("search zlib")
    #expect(try await until { !model.isSearching })
  }

  @Test func failureOfTheCurrentSearchIsShown() async throws {
    let model = makeModel(failing: ["zlib"])
    await gates.open("search zlib")
    model.search("zlib", scope: .name)
    #expect(try await until { model.errorMessage != nil })
    #expect(model.results.isEmpty)
    #expect(!model.isSearching)
  }
}
