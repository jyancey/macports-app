// Freshness.swift - Tracks when a tab's data was loaded so it can be reused until stale.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
/// When a tab's data was last loaded, so showing the tab again can reuse it
/// until it is older than `maxAge` or something invalidates it.
struct Freshness {
  let maxAge: Duration
  private var loaded: ContinuousClock.Instant?
  private var epoch = 0

  init(maxAge: Duration = .seconds(10 * 60)) {
    self.maxAge = maxAge
  }

  var isStale: Bool {
    guard let loaded else { return true }
    return ContinuousClock.now - loaded > maxAge
  }

  /// Call when a load starts; pass the token to `markLoaded` when it succeeds.
  func begin() -> Int { epoch }

  /// Records a successful load, unless the data was invalidated while it ran
  /// (its result may predate the change).
  mutating func markLoaded(_ token: Int) {
    if token == epoch { loaded = .now }
  }

  mutating func invalidate() {
    epoch += 1
    loaded = nil
  }
}
