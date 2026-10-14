// AppUpdateModel.swift - Checks GitHub for a newer MacPortsApp and remembers what was found.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import PortsKit

/// Whether a newer MacPortsApp has been released. App-wide, so every window
/// and the Settings window show the same answer. The check reads GitHub's
/// public releases list; the update itself is downloaded by the user from the
/// release page.
@MainActor
@Observable
final class AppUpdateModel {
  static let autoCheckKey = "checkForAppUpdates"
  static let prereleasesKey = "includeAppPrereleases"
  static let lastCheckKey = "lastAppUpdateCheck"
  static let skippedKey = "skippedAppVersion"
  /// How long after a check the automatic one waits to check again.
  static let checkInterval: TimeInterval = 24 * 60 * 60

  enum Outcome: Equatable {
    case updateAvailable(AppRelease)
    case upToDate
    case failed(String)
  }

  /// The newer release the last check found, whether or not it was skipped.
  private(set) var latest: AppRelease?
  private(set) var isChecking = false
  /// How the last manual or automatic check ended; nil before the first.
  private(set) var outcome: Outcome?
  /// The version the user chose to skip, so its bar stays hidden.
  private(set) var skippedTag: String?

  typealias Fetch = @Sendable (URL) async throws -> Data
  let currentVersion: AppVersion
  private let defaults: UserDefaults
  private let fetch: Fetch
  private let now: @Sendable () -> Date

  init(
    currentVersion: AppVersion = AppVersion(AppInfo.version) ?? AppVersion("0")!,
    defaults: UserDefaults = .standard,
    fetch: @escaping Fetch = AppUpdateModel.download,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.currentVersion = currentVersion
    self.defaults = defaults
    self.fetch = fetch
    self.now = now
    skippedTag = defaults.string(forKey: Self.skippedKey)
  }

  var autoCheck: Bool { defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true }
  var includePrereleases: Bool { defaults.bool(forKey: Self.prereleasesKey) }

  /// The release to tell the user about: newer, and not skipped.
  var offered: AppRelease? {
    guard let latest, latest.tag != skippedTag else { return nil }
    return latest
  }

  /// Checks when automatic checks are on and none ran in the last day.
  func checkIfDue() async {
    guard autoCheck, !isChecking else { return }
    let last = defaults.object(forKey: Self.lastCheckKey) as? Date
    if let last, now().timeIntervalSince(last) < Self.checkInterval { return }
    await check()
  }

  /// Asks GitHub now; also what "Check for Updates" does.
  @discardableResult
  func check() async -> Outcome {
    guard !isChecking else { return outcome ?? .upToDate }
    isChecking = true
    defer { isChecking = false }
    let result: Outcome
    do {
      let releases = try AppReleases.parse(try await fetch(AppReleases.listURL))
      defaults.set(now(), forKey: Self.lastCheckKey)
      latest = AppReleases.newest(
        in: releases, after: currentVersion, includePrereleases: includePrereleases)
      result = latest.map(Outcome.updateAvailable) ?? .upToDate
    } catch is CancellationError {
      return outcome ?? .upToDate
    } catch {
      result = .failed(error.localizedDescription)
    }
    outcome = result
    return result
  }

  /// Hides the bar for this version; a later release is offered again.
  func skip(_ release: AppRelease) {
    skippedTag = release.tag
    defaults.set(release.tag, forKey: Self.skippedKey)
  }

  /// Forgets the skipped version, such as when the user checks by hand.
  func clearSkipped() {
    skippedTag = nil
    defaults.removeObject(forKey: Self.skippedKey)
  }

  /// Fetches `url` from GitHub.
  nonisolated static func download(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("MacPortsApp/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      throw DownloadError.status(http.statusCode)
    }
    return data
  }

  enum DownloadError: LocalizedError {
    case status(Int)

    var errorDescription: String? {
      switch self {
      case .status(403), .status(429):
        "GitHub is limiting requests right now. Try again later."
      case .status(let code): "GitHub answered with status \(code)."
      }
    }
  }
}
