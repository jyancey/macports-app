// BinaryArchive.swift - Handles MacPorts binary archive availability and parsing.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation

/// Whether MacPorts can fetch a pre-built binary archive for a port instead
/// of compiling it.
public enum BinaryAvailability: Equatable, Sendable {
  case available
  case unavailable
  /// The archive server couldn't be reached.
  case unknown
}

public enum BinaryArchive {
  public static let archiveSite = URL(string: "https://packages.macports.org")!

  /// The archive platform tag for this Mac, such as `darwin_27` and `arm64`.
  public static func currentPlatform() -> (platform: String, arch: String) {
    var info = utsname()
    uname(&info)
    func string<T>(_ field: T) -> String {
      withUnsafeBytes(of: field) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
      }
    }
    let major = string(info.release).split(separator: ".").first.map(String.init) ?? "0"
    let machine = string(info.machine)
    return ("darwin_" + major, machine == "arm64" ? "arm64" : "x86_64")
  }

  /// Archive file names (`*.tbz2`) found in an archive-site directory listing.
  public static func parseListing(_ html: String) -> [String] {
    var names: [String] = []
    var rest = html[...]
    while let range = rest.range(of: "href=\"") {
      rest = rest[range.upperBound...]
      guard let end = rest.firstIndex(of: "\"") else { break }
      let href = String(rest[..<end])
      rest = rest[end...]
      guard href.hasSuffix(".tbz2"), let last = href.split(separator: "/").last else { continue }
      names.append(String(last).removingPercentEncoding ?? String(last))
    }
    return names
  }

  /// True when `listing` has an archive of `name` at this version and
  /// revision, built with exactly `variants`, for `platform`/`arch` (or
  /// platform-independent).
  public static func hasArchive(
    in listing: some Collection<String>, name: String, version: String, revision: Int,
    variants: [String], platform: String, arch: String
  ) -> Bool {
    let base = "\(name)-\(version)_\(revision)" + variants.sorted().map { "+" + $0 }.joined()
    let suffixes = [
      ".\(platform).\(arch).tbz2", ".darwin_any.noarch.tbz2", ".any_any.noarch.tbz2",
      ".darwin_any.\(arch).tbz2",
    ]
    return suffixes.contains { listing.contains(base + $0) }
  }

  /// True when `listing` has any archive of `name` for `platform`/`arch` (or
  /// platform-independent), whatever its version or variants. A cheap hint
  /// for lists; the detail view checks exactly.
  public static func hasAnyArchive(
    in listing: some Collection<String>, name: String, platform: String, arch: String
  ) -> Bool {
    let suffixes = [
      ".\(platform).\(arch).tbz2", ".darwin_any.noarch.tbz2", ".any_any.noarch.tbz2",
      ".darwin_any.\(arch).tbz2",
    ]
    return listing.contains { file in
      file.hasPrefix(name + "-") && suffixes.contains { file.hasSuffix($0) }
    }
  }

  /// Whether the archive site has any build of `name` for this Mac.
  /// Best effort: failures are `.unknown`.
  public static func anyBuildAvailability(name: String) async -> BinaryAvailability {
    await anyBuildAvailability(name: name, cache: .shared)
  }

  static func anyBuildAvailability(name: String, cache: ArchiveListingCache) async
    -> BinaryAvailability
  {
    await lookUp(name, in: cache) { files in
      hasAnyArchive(in: files, name: name, platform: platform.platform, arch: platform.arch)
    }
  }

  /// Looks the port up on the archive site. Best effort: any failure
  /// is `.unknown`.
  public static func availability(
    name: String, version: String, revision: Int, variants: [String]
  ) async -> BinaryAvailability {
    await availability(
      name: name, version: version, revision: revision, variants: variants, cache: .shared)
  }

  static func availability(
    name: String, version: String, revision: Int, variants: [String], cache: ArchiveListingCache
  ) async -> BinaryAvailability {
    await lookUp(name, in: cache) { files in
      hasArchive(
        in: files, name: name, version: version, revision: revision,
        variants: variants, platform: platform.platform, arch: platform.arch)
    }
  }

  /// This Mac's platform tag never changes while the app runs.
  private static let platform = currentPlatform()

  private static func lookUp(
    _ name: String, in cache: ArchiveListingCache, matches: (Set<String>) -> Bool
  ) async -> BinaryAvailability {
    guard PortClient.isValidPortName(name) else { return .unknown }
    switch try? await cache.listing(for: name) {
    case .files(let files): return matches(files) ? .available : .unavailable
    case .missing: return .unavailable
    case nil: return .unknown
    }
  }
}
