// UpdateNotifier.swift - Shows the number of outdated ports on the Dock icon and notifies when a sync finds new ones.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import AppKit
import PortsKit
import UserNotifications

/// What to show for outdated ports. Pure, so it can be tested.
enum UpdateAlert {
  /// The Dock badge: the count, or nothing when there are none or it's off.
  static func badgeLabel(count: Int, enabled: Bool) -> String {
    enabled && count > 0 ? String(count) : ""
  }

  /// The ports in `outdated` that weren't there the last time we told the user.
  static func newUpdates(in outdated: [OutdatedPort], notified: Set<String>) -> [OutdatedPort] {
    outdated.filter { !notified.contains($0.name) }
  }

  /// "3 ports can be upgraded", naming the new ones.
  static func message(new: [OutdatedPort], total: Int, nameLimit: Int = 3) -> (
    title: String, body: String
  ) {
    let names = new.prefix(nameLimit).map(\.name).joined(separator: ", ")
    let more = new.count - nameLimit
    let list = more > 0 ? "\(names) and \(more) more" : names
    return (
      "Updates available",
      "\(counted(total, "port")) can be upgraded. New: \(list)."
    )
  }
}

/// Keeps the Dock badge in step with the outdated count and, after a sync,
/// notifies about updates not reported before. One instance serves every
/// window, so the same sync never notifies twice.
@MainActor
final class UpdateNotifier {
  static let badgeKey = "showUpdateBadge"
  static let notifyKey = "notifyOnUpdates"
  static let shared = UpdateNotifier()

  private let defaults: UserDefaults
  private let setBadge: @MainActor (String) -> Void
  private let post: @MainActor (_ title: String, _ body: String) -> Void
  /// Names of the outdated ports at the last check that notified or found nothing new.
  private(set) var notified: Set<String> = []

  /// The defaults talk to the Dock and Notification Center; tests substitute their own.
  init(
    defaults: UserDefaults = .standard,
    setBadge: @escaping @MainActor (String) -> Void = { NSApp?.dockTile.badgeLabel = $0 },
    post: @escaping @MainActor (String, String) -> Void = UpdateNotifier.postNotification
  ) {
    self.defaults = defaults
    self.setBadge = setBadge
    self.post = post
  }

  var badgeEnabled: Bool { defaults.object(forKey: Self.badgeKey) as? Bool ?? true }
  var notifyEnabled: Bool { defaults.object(forKey: Self.notifyKey) as? Bool ?? false }

  /// The count last passed to `updateBadge`, to redraw when the setting changes.
  private(set) var lastCount = 0

  func updateBadge(count: Int) {
    lastCount = count
    setBadge(UpdateAlert.badgeLabel(count: count, enabled: badgeEnabled))
  }

  /// Call with the outdated list loaded after a sync or self-update. Notifies
  /// when it has ports not seen at the previous check, if the user turned that on.
  func syncFinished(outdated: [OutdatedPort]) {
    let new = UpdateAlert.newUpdates(in: outdated, notified: notified)
    notified = Set(outdated.map(\.name))
    guard notifyEnabled, !new.isEmpty else { return }
    let text = UpdateAlert.message(new: new, total: outdated.count)
    post(text.title, text.body)
  }

  /// Asks macOS for permission to notify; called when the user turns it on.
  static func requestAuthorization() {
    guard Bundle.main.bundleIdentifier != nil else { return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  /// Does nothing when run unbundled (`swift run`), which has no notification center.
  private static func postNotification(title: String, body: String) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "updates-available", content: content, trigger: nil))
  }
}
