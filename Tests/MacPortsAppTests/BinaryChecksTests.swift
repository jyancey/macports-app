import PortsKit
import Testing

@testable import MacPortsApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BinaryChecksTests {
  /// Collects what `checkBinariesInBatches` delivers.
  @MainActor final class Deliveries {
    var batches: [[String: BinaryAvailability]] = []
    var all: [String: BinaryAvailability] { batches.reduce(into: [:]) { $0.merge($1) { $1 } } }
  }

  let gates = Gates()

  /// Checks names through the gates ("check <name>"); every port is available.
  func run(
    _ names: [String], interval: Duration = .milliseconds(300), into deliveries: Deliveries
  ) -> Task<Void, Never> {
    let gates = gates
    return Task {
      await checkBinariesInBatches(names, interval: interval) { name in
        try? await gates.pass("check \(name)")
        return (name, .available)
      } deliver: { batch in
        deliveries.batches.append(batch)
      }
    }
  }

  @Test func answersArrivingTogetherAreDeliveredTogether() async throws {
    let names = (1...50).map { "port\($0)" }
    for name in names { await gates.open("check \(name)") }
    let deliveries = Deliveries()
    await run(names, into: deliveries).value
    #expect(deliveries.all.count == 50)
    // The first answer at once, the rest in one batch: not 50 redraws.
    #expect(deliveries.batches.count <= 3)
  }

  @Test func firstAnswerIsImmediateAndLaterOnesWaitForTheInterval() async throws {
    let deliveries = Deliveries()
    let task = run(["a", "b", "c"], interval: .milliseconds(300), into: deliveries)
    await gates.open("check a")
    try #require(try await until { deliveries.batches.count == 1 })
    #expect(deliveries.batches[0] == ["a": .available])

    await gates.open("check b")
    try await Task.sleep(for: .milliseconds(50))
    #expect(deliveries.batches.count == 1)
    try #require(try await until { deliveries.batches.count == 2 })
    #expect(deliveries.batches[1] == ["b": .available])

    await gates.open("check c")
    await task.value
    #expect(deliveries.all.count == 3)
  }

  /// A slow archive lookup must not hold back answers that already arrived.
  @Test func stalledCheckDoesNotHoldBackOthers() async throws {
    let deliveries = Deliveries()
    let task = run(["a", "b", "slow"], interval: .milliseconds(100), into: deliveries)
    await gates.open("check a", "check b")
    #expect(try await until { deliveries.all.keys.sorted() == ["a", "b"] })
    await gates.open("check slow")
    await task.value
    #expect(deliveries.all.count == 3)
  }

  @Test func nothingIsDeliveredAfterCancellation() async throws {
    let deliveries = Deliveries()
    let task = run(["a", "b", "c"], into: deliveries)
    await gates.open("check a")
    #expect(try await until { deliveries.batches.count == 1 })
    task.cancel()
    await gates.open("check b", "check c")
    await task.value
    try await Task.sleep(for: .milliseconds(400))
    #expect(deliveries.batches.count == 1)
  }

  @Test func atMostSixChecksRunAtOnce() async throws {
    let names = (1...10).map { "port\($0)" }
    let deliveries = Deliveries()
    let task = run(names, into: deliveries)
    #expect(try await gates.waitForCall("check port6"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(await gates.calls.count == 6)
    for name in names { await gates.open("check \(name)") }
    await task.value
    #expect(deliveries.all.count == 10)
  }
}
