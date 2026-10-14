// UpdateNotifierTests.swift - Tests for the Dock badge and update notifications.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import PortsKit
import Testing

@testable import MacPortsApp

@Suite struct UpdateAlertTests {
  func outdated(_ names: String...) -> [OutdatedPort] {
    names.map { OutdatedPort(name: $0, installedVersion: "1", availableVersion: "2") }
  }

  @Test func badgeShowsTheCountOnlyWhenThereIsOneToShow() {
    #expect(UpdateAlert.badgeLabel(count: 4, enabled: true) == "4")
    #expect(UpdateAlert.badgeLabel(count: 0, enabled: true) == "")
    #expect(UpdateAlert.badgeLabel(count: 4, enabled: false) == "")
  }

  @Test func onlyUnreportedPortsAreNew() {
    let list = outdated("git", "zlib", "xz")
    #expect(UpdateAlert.newUpdates(in: list, notified: []).map(\.name) == ["git", "zlib", "xz"])
    #expect(UpdateAlert.newUpdates(in: list, notified: ["git", "xz"]).map(\.name) == ["zlib"])
    #expect(UpdateAlert.newUpdates(in: list, notified: ["git", "zlib", "xz"]).isEmpty)
  }

  @Test func messageNamesTheFirstFewNewPorts() {
    let one = UpdateAlert.message(new: outdated("git"), total: 1)
    #expect(one.title == "Updates available")
    #expect(one.body == "1 port can be upgraded. New: git.")
    let many = UpdateAlert.message(new: outdated("a", "b", "c", "d", "e"), total: 9)
    #expect(many.body == "9 ports can be upgraded. New: a, b, c and 2 more.")
  }
}

@MainActor
@Suite struct UpdateNotifierTests {
  final class Recorder {
    var badges: [String] = []
    var posts: [String] = []
  }

  let recorder = Recorder()
  let defaults: UserDefaults

  init() {
    defaults = UserDefaults(suiteName: "UpdateNotifierTests-\(UUID().uuidString)")!
  }

  func makeNotifier() -> UpdateNotifier {
    let recorder = recorder
    return UpdateNotifier(
      defaults: defaults, setBadge: { recorder.badges.append($0) },
      post: { title, body in recorder.posts.append("\(title): \(body)") })
  }

  func outdated(_ names: String...) -> [OutdatedPort] {
    names.map { OutdatedPort(name: $0, installedVersion: "1", availableVersion: "2") }
  }

  @Test func badgeIsOnByDefaultAndFollowsTheSetting() {
    let notifier = makeNotifier()
    notifier.updateBadge(count: 3)
    defaults.set(false, forKey: UpdateNotifier.badgeKey)
    notifier.updateBadge(count: 3)
    #expect(recorder.badges == ["3", ""])
    #expect(notifier.lastCount == 3)
  }

  @Test func notificationsAreOffByDefault() {
    let notifier = makeNotifier()
    notifier.syncFinished(outdated: outdated("git"))
    #expect(recorder.posts.isEmpty)
  }

  @Test func aSyncNotifiesOnceForTheSameUpdates() {
    defaults.set(true, forKey: UpdateNotifier.notifyKey)
    let notifier = makeNotifier()
    notifier.syncFinished(outdated: outdated("git", "zlib"))
    #expect(recorder.posts == ["Updates available: 2 ports can be upgraded. New: git, zlib."])
    notifier.syncFinished(outdated: outdated("git", "zlib"))
    #expect(recorder.posts.count == 1)
  }

  @Test func newUpdatesNotifyAgainAndNothingOutdatedStaysQuiet() {
    defaults.set(true, forKey: UpdateNotifier.notifyKey)
    let notifier = makeNotifier()
    notifier.syncFinished(outdated: outdated("git"))
    notifier.syncFinished(outdated: outdated("git", "xz"))
    #expect(recorder.posts.last == "Updates available: 2 ports can be upgraded. New: xz.")
    notifier.syncFinished(outdated: [])
    #expect(recorder.posts.count == 2)
    // Upgraded, then outdated again later: that is new again.
    notifier.syncFinished(outdated: outdated("git"))
    #expect(recorder.posts.count == 3)
  }

  @Test func turningNotificationsOffStillRemembersWhatWasSeen() {
    let notifier = makeNotifier()
    notifier.syncFinished(outdated: outdated("git"))
    defaults.set(true, forKey: UpdateNotifier.notifyKey)
    notifier.syncFinished(outdated: outdated("git"))
    #expect(recorder.posts.isEmpty)
  }
}

@MainActor
@Suite struct ActivityLastRunTests {
  @Test func completedRunsRecordWhichCommandFinished() async {
    let log = ActivityLog(onCommandEnded: {})
    #expect(log.lastCompletedName == nil)
    _ = await log.run("sudo port sync", name: "sync") { _ in }
    #expect(log.completedRuns == 1)
    #expect(log.lastCompletedName == "sync")
    _ = await log.run("sudo port upgrade zlib", name: "zlib") { _ in }
    #expect(log.lastCompletedName == "zlib")
  }
}
