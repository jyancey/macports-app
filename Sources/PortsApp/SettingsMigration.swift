// SettingsMigration.swift - Carries preferences over from the app's old bundle identifier.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import PortsKit

/// Up to 0.5.x the app's bundle identifier was `com.example.ports`; it is now
/// `io.indegree.MacPortsApp`, so the preferences saved by older versions are in
/// a defaults domain the app no longer reads. On the first launch after the
/// upgrade, this copies them across once. The old domain is left as it was.
@MainActor
enum SettingsMigration {
  static let legacyDomain = "com.example.ports"
  /// Set once the migration has run, whether or not there was anything to copy.
  static let doneKey = "migratedLegacySettings"

  /// Every key the app stores. A key added after 0.5.x needs no entry.
  static let keys = [
    PortClient.executablePathDefaultsKey,
    PortClient.verboseDefaultsKey,
    ActivityLog.autoOpenKey,
    UpdateNotifier.badgeKey,
    UpdateNotifier.notifyKey,
    AppUpdateModel.autoCheckKey,
    AppUpdateModel.prereleasesKey,
    AppUpdateModel.lastCheckKey,
    AppUpdateModel.skippedKey,
    SettingsPane.defaultsKey,
    "activityHeight",
  ]

  /// Copies each key that `legacy` has and `defaults` doesn't, then marks the
  /// migration done. Does nothing once it is done. Returns the keys copied.
  @discardableResult
  static func run(from legacy: UserDefaults?, to defaults: UserDefaults) -> [String] {
    guard !defaults.bool(forKey: doneKey) else { return [] }
    var copied: [String] = []
    if let legacy {
      for key in keys where defaults.object(forKey: key) == nil {
        guard let value = legacy.object(forKey: key) else { continue }
        defaults.set(value, forKey: key)
        copied.append(key)
      }
    }
    defaults.set(true, forKey: doneKey)
    return copied
  }

  /// Runs the migration for the app's own preferences. Call it before anything
  /// reads them.
  static func runForApp() {
    // A domain can't be opened as a suite of itself, and an unbundled run
    // (`swift run`) has nothing to migrate.
    guard let identifier = Bundle.main.bundleIdentifier, identifier != legacyDomain else { return }
    run(from: UserDefaults(suiteName: legacyDomain), to: .standard)
  }
}
