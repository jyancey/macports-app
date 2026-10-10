import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(AppInfo.name) Help").font(.largeTitle.bold())
                section("Browsing", [
                    "Installed, Outdated and Inactive list what is on your system; Available searches the whole ports tree (press Return to search).",
                    "Select a port to see its details, variants and dependencies.",
                ])
                section("Installing", [
                    "Choose variants in the detail pane before installing. A package icon marks ports that have a pre-built binary for your platform. In search results, the Pre-built column shows a green seal for ports with a binary for this Mac (first 100 results), and the toolbar's \"Pre-built only\" toggle filters to them.",
                    "Status in the Available table updates live (Downloading…, Building…, Installing…).",
                ])
                section("Upgrading and cleanup", [
                    "Outdated lists ports with newer versions; Upgrade All runs `port upgrade outdated`.",
                    "Inactive lists old versions that can be removed to reclaim space.",
                ])
                section("Activity pane", [
                    "Shows the output of every port command. Drag the divider to resize it.",
                    "Green dot: ready. Yellow: busy. Red: the last command failed.",
                ])
                section("Configuration", [
                    "Verbose output shows full port output but is slower.",
                    "Self-update and Sync refresh MacPorts and the ports tree; Diagnose runs `port diagnose`.",
                    "Commands that change your system ask for your administrator password.",
                ])
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private func section(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.bold())
            ForEach(items, id: \.self) { Text("• " + $0).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
