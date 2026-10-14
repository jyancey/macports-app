// AppRelease.swift - Versions and GitHub releases, for finding a newer MacPortsApp.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation

/// A semantic version such as `0.4.2` or `0.5.0-rc.1`, ordered by the
/// semver rules (a pre-release is older than its release).
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
  public let numbers: [Int]
  public let prerelease: [String]

  /// Parses `0.4.2`, `v0.4.2` and `0.5.0-rc.1`; nil for anything else.
  public init?(_ text: String) {
    var text = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
    if text.hasPrefix("v") || text.hasPrefix("V") { text = text.dropFirst() }
    let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard let core = parts.first else { return nil }
    let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
    self.numbers = numbers.compactMap { $0 }
    if parts.count == 2 {
      let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
      guard !identifiers.contains(where: \.isEmpty) else { return nil }
      prerelease = identifiers.map(String.init)
    } else {
      prerelease = []
    }
  }

  public var isPrerelease: Bool { !prerelease.isEmpty }

  /// `0.5.0-rc.1`.
  public var description: String {
    numbers.map(String.init).joined(separator: ".")
      + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
  }

  public static func < (a: AppVersion, b: AppVersion) -> Bool {
    let length = max(a.numbers.count, b.numbers.count)
    for index in 0..<length {
      let x = index < a.numbers.count ? a.numbers[index] : 0
      let y = index < b.numbers.count ? b.numbers[index] : 0
      if x != y { return x < y }
    }
    if a.prerelease.isEmpty || b.prerelease.isEmpty {
      return !a.prerelease.isEmpty && b.prerelease.isEmpty
    }
    for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
      switch (Int(x), Int(y)) {
      case (let m?, let n?): return m < n
      case (nil, nil): return x < y
      case (_?, nil): return true
      case (nil, _?): return false
      }
    }
    return a.prerelease.count < b.prerelease.count
  }

  /// Equal when they compare equal: `1.0` and `1.0.0` are the same version.
  public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

  public func hash(into hasher: inout Hasher) {
    var trimmed = numbers
    while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
    hasher.combine(trimmed)
    hasher.combine(prerelease)
  }
}

/// One release of MacPortsApp, from the GitHub releases API.
public struct AppRelease: Decodable, Equatable, Sendable {
  public let tag: String
  public let url: URL
  public let isPrerelease: Bool
  public let isDraft: Bool
  public let notes: String

  enum CodingKeys: String, CodingKey {
    case tag = "tag_name"
    case url = "html_url"
    case isPrerelease = "prerelease"
    case isDraft = "draft"
    case notes = "body"
  }

  public init(
    tag: String, url: URL, isPrerelease: Bool = false, isDraft: Bool = false, notes: String = ""
  ) {
    self.tag = tag
    self.url = url
    self.isPrerelease = isPrerelease
    self.isDraft = isDraft
    self.notes = notes
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    tag = try values.decode(String.self, forKey: .tag)
    url = try values.decode(URL.self, forKey: .url)
    isPrerelease = try values.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
    isDraft = try values.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
    notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
  }

  public var version: AppVersion? { AppVersion(tag) }
}

public enum AppReleases {
  public static let repository = "jyancey/macports-app"

  /// The most recent releases, newest first, including pre-releases.
  public static let listURL = URL(
    string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!

  public enum ParseError: LocalizedError {
    case unreadable

    public var errorDescription: String? { "GitHub's list of releases couldn't be read." }
  }

  public static func parse(_ data: Data) throws -> [AppRelease] {
    do { return try JSONDecoder().decode([AppRelease].self, from: data) } catch {
      throw ParseError.unreadable
    }
  }

  /// The newest release newer than `current`. Drafts, tags that aren't
  /// versions, and (unless `includePrereleases`) pre-releases are skipped.
  public static func newest(
    in releases: [AppRelease], after current: AppVersion, includePrereleases: Bool
  ) -> AppRelease? {
    releases
      .compactMap { release -> (AppRelease, AppVersion)? in
        guard !release.isDraft, let version = release.version else { return nil }
        if !includePrereleases, release.isPrerelease || version.isPrerelease { return nil }
        return version > current ? (release, version) : nil
      }
      .max { $0.1 < $1.1 }?.0
  }
}
