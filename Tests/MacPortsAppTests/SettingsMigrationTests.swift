// SettingsMigrationTests.swift - Tests for carrying preferences over from the old bundle identifier.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import PortsKit
import Testing

@testable import MacPortsApp

@MainActor
@Suite struct SettingsMigrationTests {
  let legacy = UserDefaults(suiteName: "SettingsMigrationTests-legacy-\(UUID().uuidString)")!
  let current = UserDefaults(suiteName: "SettingsMigrationTests-current-\(UUID().uuidString)")!

  @Test func copiesEverySettingTheOldVersionSaved() {
    legacy.set("/opt/local/bin/port", forKey: PortClient.executablePathDefaultsKey)
    legacy.set(true, forKey: PortClient.verboseDefaultsKey)
    legacy.set(false, forKey: AppUpdateModel.autoCheckKey)
    legacy.set(320.0, forKey: "activityHeight")

    let copied = SettingsMigration.run(from: legacy, to: current)

    #expect(Set(copied) == [
      PortClient.executablePathDefaultsKey, PortClient.verboseDefaultsKey,
      AppUpdateModel.autoCheckKey, "activityHeight",
    ])
    #expect(current.string(forKey: PortClient.executablePathDefaultsKey) == "/opt/local/bin/port")
    #expect(current.bool(forKey: PortClient.verboseDefaultsKey))
    #expect(current.object(forKey: AppUpdateModel.autoCheckKey) as? Bool == false)
    #expect(current.double(forKey: "activityHeight") == 320)
  }

  @Test func leavesTheOldDomainAlone() {
    legacy.set(true, forKey: PortClient.verboseDefaultsKey)
    SettingsMigration.run(from: legacy, to: current)
    #expect(legacy.bool(forKey: PortClient.verboseDefaultsKey))
  }

  @Test func doesNotOverwriteASettingAlreadyMadeInTheNewVersion() {
    legacy.set("/old/bin/port", forKey: PortClient.executablePathDefaultsKey)
    current.set("/new/bin/port", forKey: PortClient.executablePathDefaultsKey)

    let copied = SettingsMigration.run(from: legacy, to: current)

    #expect(copied.isEmpty)
    #expect(current.string(forKey: PortClient.executablePathDefaultsKey) == "/new/bin/port")
  }

  @Test func runsOnlyOnce() {
    SettingsMigration.run(from: legacy, to: current)
    legacy.set(true, forKey: PortClient.verboseDefaultsKey)

    #expect(SettingsMigration.run(from: legacy, to: current).isEmpty)
    #expect(current.object(forKey: PortClient.verboseDefaultsKey) == nil)
  }

  @Test func aFreshInstallHasNothingToCopyButIsMarkedDone() {
    #expect(SettingsMigration.run(from: legacy, to: current).isEmpty)
    #expect(current.bool(forKey: SettingsMigration.doneKey))
  }

  @Test func noOldDomainAtAllIsMarkedDone() {
    #expect(SettingsMigration.run(from: nil, to: current).isEmpty)
    #expect(current.bool(forKey: SettingsMigration.doneKey))
  }

  @Test func ignoresKeysTheAppDoesNotOwn() {
    legacy.set("x", forKey: "NSWindow Frame main")
    SettingsMigration.run(from: legacy, to: current)
    #expect(current.object(forKey: "NSWindow Frame main") == nil)
  }
}
