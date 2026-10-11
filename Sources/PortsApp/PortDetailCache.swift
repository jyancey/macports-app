import Observation
import PortsKit

/// What the detail pane has already loaded for each port, so showing a port
/// again doesn't run `port`. Only successful results are kept. `ContentView`
/// clears it after any command, since the command may have changed them.
@MainActor
@Observable
final class PortDetailCache {
  struct Entry {
    var info: PortInfo?
    var files: [String]?
    var dependents: [String]?
    /// Names of the variants enabled by default (from `port variants`).
    var defaultVariants: [String]?
    /// Only definite answers; `.unknown` (archive site unreachable) is retried.
    var binary: BinaryAvailability?
    var tree: [PortInfoParser.DependencyNode]?
  }

  private typealias Stored = (entry: Entry, created: ContinuousClock.Instant)
  @ObservationIgnored private var entries: [String: Stored] = [:]
  @ObservationIgnored let maxAge: Duration

  init(maxAge: Duration = .seconds(10 * 60)) {
    self.maxAge = maxAge
  }

  /// The cached results for `name`; empty when none are cached or they have
  /// expired.
  subscript(name: String) -> Entry {
    get {
      guard let stored = entries[name] else { return Entry() }
      guard ContinuousClock.now - stored.created <= maxAge else {
        entries[name] = nil
        return Entry()
      }
      return stored.entry
    }
    set {
      entries[name] = (newValue, entries[name]?.created ?? .now)
    }
  }

  func removeAll() { entries.removeAll() }
}
