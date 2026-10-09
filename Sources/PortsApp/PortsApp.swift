import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets the app show a window and menu bar when launched via `swift run`.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum AppInfo {
    static let name = "Ports"
    static let version = "0.1.0"
    static let build = "1"
    static let author = "John Yancey"
    static let copyright = "© 2026 John Yancey"
}

@main
struct PortsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var activity = ActivityLog()

    var body: some Scene {
        WindowGroup("Ports") {
            ContentView()
                .environment(activity)
                .frame(minWidth: 900, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppInfo.name)") { showAbout() }
            }
        }
    }

    private func showAbout() {
        let credits = NSMutableAttributedString(
            string: "A native macOS interface for MacPorts.\nCreated by \(AppInfo.author).",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.labelColor])
        credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .version: AppInfo.build,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): AppInfo.copyright,
        ])
    }
}
