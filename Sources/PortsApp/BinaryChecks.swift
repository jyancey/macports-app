// BinaryChecks.swift - Checks pre-built binary availability for many ports in throttled batches.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import PortsKit

private enum BinaryCheckEvent: Sendable {
  case answer(String, BinaryAvailability)
  /// The throttle interval has passed.
  case tick
}

/// Checks pre-built availability for `items`, at most six at a time. Answers
/// are passed to `deliver` in batches, the first at once and then at most once
/// per `interval`, so a list filtered on them ("Pre-built only") is redrawn a
/// few times instead of once per port. Nothing is delivered after the calling
/// task is cancelled.
@MainActor
func checkBinariesInBatches<Item: Sendable>(
  _ items: [Item], interval: Duration = .milliseconds(200),
  check: @escaping @Sendable (Item) async -> (name: String, result: BinaryAvailability),
  deliver: ([String: BinaryAvailability]) -> Void
) async {
  await withTaskGroup(of: BinaryCheckEvent.self) { group in
    var remaining = items.makeIterator()
    var running = 0
    func startNext() {
      guard let item = remaining.next() else { return }
      running += 1
      group.addTask {
        let (name, result) = await check(item)
        return .answer(name, result)
      }
    }
    for _ in 0..<6 { startNext() }

    var pending: [String: BinaryAvailability] = [:]
    var throttling = false
    func scheduleTick() {
      throttling = true
      group.addTask {
        try? await Task.sleep(for: interval)
        return .tick
      }
    }
    while running > 0, let event = await group.next() {
      guard !Task.isCancelled else {
        group.cancelAll()
        return
      }
      switch event {
      case .answer(let name, let result):
        running -= 1
        startNext()
        pending[name] = result
        if !throttling {
          deliver(pending)
          pending = [:]
          scheduleTick()
        }
      case .tick:
        if pending.isEmpty {
          throttling = false
        } else {
          deliver(pending)
          pending = [:]
          scheduleTick()
        }
      }
    }
    // Stops a pending tick; what is left is delivered now rather than after it.
    group.cancelAll()
    guard !Task.isCancelled else { return }
    if !pending.isEmpty { deliver(pending) }
  }
}
