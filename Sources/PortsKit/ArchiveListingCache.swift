import Foundation

/// Archive-site directory listings, cached per port so the search list, detail
/// pane, install sheet and Outdated tab share one download. Requests for a
/// port that is already being fetched wait for that download. Failures are
/// not cached, so the next request tries again.
public actor ArchiveListingCache {
  public enum Listing: Sendable, Hashable {
    /// Archive file names in the port's directory.
    case files(Set<String>)
    /// The archive site has no directory for the port (HTTP 404).
    case missing
  }

  public typealias Fetch = @Sendable (_ name: String) async throws -> Listing

  public static let shared = ArchiveListingCache()

  private let fetch: Fetch
  private let maxAge: Duration
  private let limit: Int
  private let clock = ContinuousClock()
  private var entries: [String: (listing: Listing, fetched: ContinuousClock.Instant)] = [:]
  private var inFlight: [String: Task<Listing, any Error>] = [:]

  /// Listings older than `maxAge` are fetched again; past `limit` entries the
  /// oldest is dropped.
  public init(
    maxAge: Duration = .seconds(10 * 60), limit: Int = 1000,
    fetch: @escaping Fetch = ArchiveListingCache.download
  ) {
    self.maxAge = maxAge
    self.limit = limit
    self.fetch = fetch
  }

  public func listing(for name: String) async throws -> Listing {
    if let entry = entries[name], clock.now - entry.fetched < maxAge { return entry.listing }
    if let pending = inFlight[name] { return try await pending.value }
    let fetch = self.fetch
    let task = Task { try await fetch(name) }
    inFlight[name] = task
    defer { inFlight[name] = nil }
    let listing = try await task.value
    store(listing, for: name)
    return listing
  }

  /// Drops every cached listing.
  public func removeAll() { entries.removeAll() }

  private func store(_ listing: Listing, for name: String) {
    entries[name] = (listing, clock.now)
    if entries.count > limit,
      let oldest = entries.min(by: { $0.value.fetched < $1.value.fetched })?.key
    {
      entries[oldest] = nil
    }
  }

  struct UnexpectedStatus: Error {
    let code: Int
  }

  /// Downloads and parses a port's directory listing from the archive site.
  public static func download(_ name: String) async throws -> Listing {
    var request = URLRequest(
      url: BinaryArchive.archiveSite.appendingPathComponent(name, isDirectory: true))
    request.timeoutInterval = 10
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw UnexpectedStatus(code: 0) }
    if http.statusCode == 404 { return .missing }
    guard http.statusCode == 200 else { throw UnexpectedStatus(code: http.statusCode) }
    return .files(Set(BinaryArchive.parseListing(String(decoding: data, as: UTF8.self))))
  }
}
