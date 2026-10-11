import Foundation
import Testing

@testable import PortsKit

@Suite(.timeLimit(.minutes(1))) struct ArchiveListingCacheTests {
  struct Offline: Error {}

  /// A fake archive site that counts downloads and can hold them until released.
  actor Site {
    private(set) var downloads: [String] = []
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var failing: Set<String> = []

    func hold() { held = true }

    func release() {
      held = false
      for waiter in waiting { waiter.resume() }
      waiting.removeAll()
    }

    func setFailing(_ names: Set<String>) { failing = names }

    func fetch(_ name: String) async throws -> ArchiveListingCache.Listing {
      downloads.append(name)
      if held { await withCheckedContinuation { waiting.append($0) } }
      if failing.contains(name) { throw Offline() }
      if name == "nothing" { return .missing }
      return .files(["\(name)-1.0_0.darwin_27.arm64.tbz2"])
    }
  }

  let site = Site()

  func makeCache(maxAge: Duration = .seconds(600), limit: Int = 1000) -> ArchiveListingCache {
    let site = site
    return ArchiveListingCache(maxAge: maxAge, limit: limit) { try await site.fetch($0) }
  }

  @Test func repeatedRequestsShareOneDownload() async throws {
    let cache = makeCache()
    _ = try await cache.listing(for: "zlib")
    _ = try await cache.listing(for: "zlib")
    #expect(await site.downloads == ["zlib"])
  }

  @Test func concurrentRequestsWaitForTheSameDownload() async throws {
    let cache = makeCache()
    await site.hold()
    async let first = cache.listing(for: "zlib")
    async let second = cache.listing(for: "zlib")
    async let third = cache.listing(for: "zlib")
    while await site.downloads.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    try await Task.sleep(for: .milliseconds(50))
    await site.release()
    let listings = try await [first, second, third]
    #expect(Set(listings).count == 1)
    #expect(await site.downloads == ["zlib"])
  }

  @Test func expiredListingsAreFetchedAgain() async throws {
    let cache = makeCache(maxAge: .zero)
    _ = try await cache.listing(for: "zlib")
    _ = try await cache.listing(for: "zlib")
    #expect(await site.downloads == ["zlib", "zlib"])
  }

  @Test func failuresAreNotCached() async throws {
    let cache = makeCache()
    await site.setFailing(["zlib"])
    await #expect(throws: Offline.self) { try await cache.listing(for: "zlib") }
    await site.setFailing([])
    #expect(try await cache.listing(for: "zlib") == .files(["zlib-1.0_0.darwin_27.arm64.tbz2"]))
    #expect(await site.downloads == ["zlib", "zlib"])
  }

  @Test func missingPortsAreCached() async throws {
    let cache = makeCache()
    #expect(try await cache.listing(for: "nothing") == .missing)
    #expect(try await cache.listing(for: "nothing") == .missing)
    #expect(await site.downloads == ["nothing"])
  }

  @Test func oldestListingIsDroppedPastTheLimit() async throws {
    let cache = makeCache(limit: 2)
    for name in ["a", "b", "c", "b", "c", "a"] { _ = try await cache.listing(for: name) }
    #expect(await site.downloads == ["a", "b", "c", "a"])
  }

  @Test func availabilityAnswersFromTheCachedListing() async throws {
    let cache = makeCache()
    let (platform, arch) = BinaryArchive.currentPlatform()
    let site = site
    let exact = ArchiveListingCache { name in
      await site.fetchCount(name)
      return .files(["\(name)-1.0_0+x11.\(platform).\(arch).tbz2"])
    }
    #expect(
      await BinaryArchive.availability(
        name: "zlib", version: "1.0", revision: 0, variants: ["x11"], cache: exact) == .available)
    #expect(
      await BinaryArchive.availability(
        name: "zlib", version: "1.0", revision: 0, variants: [], cache: exact) == .unavailable)
    #expect(await BinaryArchive.anyBuildAvailability(name: "zlib", cache: exact) == .available)
    #expect(await site.downloads == ["zlib"])

    #expect(await BinaryArchive.anyBuildAvailability(name: "nothing", cache: cache) == .unavailable)
    await site.setFailing(["offline"])
    #expect(await BinaryArchive.anyBuildAvailability(name: "offline", cache: cache) == .unknown)
    #expect(await BinaryArchive.anyBuildAvailability(name: "a;b", cache: cache) == .unknown)
  }
}

extension ArchiveListingCacheTests.Site {
  /// Records a download without returning a listing.
  func fetchCount(_ name: String) { downloads.append(name) }
}
