// TestSupport.swift - Shared helpers for the app tests.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Testing

/// Holds each fake query until the test opens its gate, and records every call.
/// Like `PortClient`, a cancelled query stops waiting and throws.
actor Gates {
  private var opened: Set<String> = []
  private var waiters: [String: [(id: Int, continuation: CheckedContinuation<Void, Never>)]] = [:]
  private var nextID = 0
  private(set) var calls: [String] = []
  /// Queries that stopped waiting because their task was cancelled.
  private(set) var cancelled: [String] = []

  func pass(_ key: String) async throws {
    calls.append(key)
    guard !opened.contains(key) else { return }
    let id = nextID
    nextID += 1
    // The handler's task can only run on this actor after the waiter is stored.
    await withTaskCancellationHandler {
      await withCheckedContinuation { waiters[key, default: []].append((id, $0)) }
    } onCancel: {
      Task { await self.release(id) }
    }
    try Task.checkCancellation()
  }

  func open(_ keys: String...) {
    for key in keys {
      opened.insert(key)
      for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.continuation.resume() }
    }
  }

  /// Like `pass`, but keeps waiting after cancellation, as a query that
  /// ignores cancellation would.
  func passIgnoringCancellation(_ key: String) async {
    calls.append(key)
    guard !opened.contains(key) else { return }
    let id = nextID
    nextID += 1
    await withCheckedContinuation { waiters[key, default: []].append((id, $0)) }
  }

  /// Polls until `key` has been called; false on timeout.
  func waitForCall(_ key: String) async throws -> Bool {
    try await poll { $0.calls.contains(key) }
  }

  /// Polls until the query `key` has been cancelled; false on timeout.
  func waitForCancellation(_ key: String) async throws -> Bool {
    try await poll { $0.cancelled.contains(key) }
  }

  private func poll(_ condition: (isolated Gates) -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while !condition(self) {
      guard clock.now < deadline else { return false }
      try await Task.sleep(for: .milliseconds(2))
    }
    return true
  }

  private func release(_ id: Int) {
    for (key, list) in waiters {
      if let index = list.firstIndex(where: { $0.id == id }) {
        cancelled.append(key)
        waiters[key]?.remove(at: index).continuation.resume()
      }
    }
  }
}

/// Polls until `condition` holds; false on timeout.
@MainActor func until(_ condition: () -> Bool) async throws -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(5)
  while !condition() {
    guard clock.now < deadline else { return false }
    try await Task.sleep(for: .milliseconds(2))
  }
  return true
}
