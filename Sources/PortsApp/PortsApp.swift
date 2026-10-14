// PortsApp.swift - Main entry point for the MacPortsApp SwiftUI application.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  /// Shows the update notification even while the app is in front, such as
  /// when the sync was started from its own window.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Unbundled runs (`swift run`) have no notification center.
    if Bundle.main.bundleIdentifier != nil {
      UNUserNotificationCenter.current().delegate = self
    }
    // Lets the app show a window and menu bar when launched via `swift run`.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}

enum AppInfo {
  static let name = "MacPortsApp"
  // Fallback used when run unbundled (`swift run`); packaged builds read Info.plist.
  static let version =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.2"
  static let build =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0.4.2"
  static let author = "John Yancey"
  static let copyright = "© 2026 John Yancey"
}

@main
struct MacPortsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var activity = ActivityLog()
  // Shared by every window and the Settings window.
  @State private var configuration = ConfigurationModel()
  @State private var health = HealthModel()
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    WindowGroup {
      ContentView(activity: activity, configuration: configuration)
        .environment(activity)
        // Must be at least the sum of the three columns' minimum widths
        // (150 + 380 + 590), or the detail column gets squeezed below its
        // minimum and its toolbar controls spill into the content column.
        .frame(minWidth: 1170, minHeight: 500)
    }
    .commands {
      AppCommands(activity: activity, configuration: configuration)
      CommandGroup(replacing: .appInfo) {
        Button("About \(AppInfo.name)") { showAbout() }
      }
      CommandGroup(replacing: .help) {
        Button("\(AppInfo.name) Help") { openWindow(id: "help") }
          .keyboardShortcut("?", modifiers: .command)
        Divider()
        Link("MacPorts Guide", destination: URL(string: "https://guide.macports.org")!)
        Link("MacPorts Website", destination: URL(string: "https://www.macports.org")!)
        Link("Browse All Ports", destination: URL(string: "https://ports.macports.org")!)
        Link(
          "Report a MacPorts Problem",
          destination: URL(string: "https://trac.macports.org/newticket")!)
      }
    }
    Window("\(AppInfo.name) Help", id: "help") { HelpView() }
    Settings {
      SettingsView(configuration: configuration, health: health)
        .environment(activity)
    }
  }

  private func showAbout() {
    let credits = NSMutableAttributedString(
      string: "A native macOS interface for MacPorts.\nCreated by \(AppInfo.author).",
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.labelColor,
      ])
    credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
    var options: [NSApplication.AboutPanelOptionKey: Any] = [
      .applicationName: AppInfo.name,
      .applicationVersion: AppInfo.version,
      .version: AppInfo.build == AppInfo.version ? "" : AppInfo.build,
      .credits: credits,
      NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): AppInfo.copyright,
    ]
    if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
      let icon = NSImage(contentsOf: url)
    {
      options[.applicationIcon] = icon
    }
    NSApp.orderFrontStandardAboutPanel(options: options)
  }
}
