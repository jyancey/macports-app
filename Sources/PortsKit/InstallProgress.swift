import Foundation

/// Where a port is in an install, as reported by `port -v install` output.
public enum PortProgress: Equatable, Sendable {
  case queued
  case working(String)
  case done
}

/// Follows `--->` lines from a verbose MacPorts run and tracks each port it
///  mentions, including dependencies that get installed along the way.
public struct InstallProgressParser: Sendable {
  public private(set) var statuses: [String: PortProgress] = [:]
  private var partial = ""
  private var inQueueList = false

  public init() {}

  private static let phases: [(verb: String, label: String)] = [
    ("Computing dependencies", "Preparing"), ("Fetching", "Downloading"),
    ("Verifying", "Verifying"), ("Extracting", "Extracting"), ("Applying", "Patching"),
    ("Configuring", "Configuring"), ("Building", "Building"), ("Staging", "Staging"),
    ("Installing", "Installing"), ("Activating", "Activating"),
  ]

  /// Feeds raw output; incomplete trailing lines are held until their newline
  /// arrives.
  public mutating func consume(_ text: String) {
    partial += text
    var lines = partial.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    partial = lines.removeLast()
    for line in lines { consumeLine(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  private mutating func consumeLine(_ line: String) {
    if line.hasPrefix("The following dependencies will be") {
      inQueueList = true
      return
    }
    if inQueueList {
      let names = line.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
      if line.isEmpty || line.hasPrefix("--->")
        || names.contains(where: { !PortClient.isValidPortName($0) })
      {
        inQueueList = false
      } else {
        for n in names where statuses[n] == nil { statuses[n] = .queued }
        return
      }
    }
    guard line.hasPrefix("--->") else { return }
    var text = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
    if text.hasSuffix(".") { text.removeLast() }

    if text.hasPrefix("Cleaning "), let name = Self.name(in: text, verb: "Cleaning") {
      statuses[name] = .done
      return
    }
    for (verb, label) in Self.phases where text.hasPrefix(verb) {
      if let name = Self.name(in: text, verb: verb) { statuses[name] = .working(label) }
      return
    }
  }

  /// "Fetching archive for zlib" -> zlib; "Building zlib" -> zlib;
  /// "Installing zlib @1.3_0" -> zlib.
  private static func name(in text: String, verb: String) -> String? {
    var rest = String(text.dropFirst(verb.count))
    if let r = rest.range(of: " for ", options: .backwards) {
      rest = String(rest[r.upperBound...])
    } else if let r = rest.range(of: " into ") {
      rest = String(rest[..<r.lowerBound])
    }
    rest = rest.trimmingCharacters(in: .whitespaces)
    let first = rest.split(separator: " ").first.map(String.init) ?? ""
    return PortClient.isValidPortName(first) ? first : nil
  }
}
