import SwiftUI
import PortsKit

/// App preferences and facts about the local MacPorts installation.
struct ConfigurationView: View {
    @AppStorage(PortClient.verboseDefaultsKey) private var verbose = false
    @Environment(ActivityLog.self) private var activity
    @State private var info: MacPortsInfo?
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Activity") {
                Toggle("Verbose output", isOn: $verbose)
                Text("Passes -v to port so the Activity pane shows full configure and build output. "
                     + "Turn it off for faster, quieter runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("MacPorts") {
                if let info {
                    row("Version", info.version)
                    row("Executable", info.executablePath)
                    row("Prefix", info.prefix)
                    row("Data directory", info.dataPath)
                    row("Applications", info.applicationsDir)
                    row("Installed ports", "\(info.installedCount)")
                    row("Last sync", info.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                    ForEach(Array(info.sources.enumerated()), id: \.offset) { i, src in
                        row(i == 0 ? "Sources" : "", src)
                    }
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            Section("Maintenance") {
                HStack {
                    Button("Self-update", systemImage: "arrow.triangle.2.circlepath") {
                        runMaintenance("sudo port selfupdate", name: "selfupdate") { try await $0.selfupdate(onOutput: $1) }
                    }
                    Button("Sync", systemImage: "arrow.down.circle") {
                        runMaintenance("sudo port sync", name: "sync") { try await $0.sync(onOutput: $1) }
                    }
                }
                .disabled(activity.isRunning)
                Text("Self-update upgrades MacPorts itself and refreshes the ports tree. "
                     + "Sync refreshes the ports tree only. Both ask for your administrator password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Troubleshooting") {
                Button("Diagnose", systemImage: "stethoscope") {
                    Task {
                        await activity.run("port diagnose", name: "diagnose") { out in
                            let text = try await PortClient().diagnose()
                            out(text.isEmpty ? "No problems found.\n" : text)
                        }
                    }
                }
                .disabled(activity.isRunning)
                Text("Runs port diagnose to check your environment for common problems. Results appear in the Activity pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await loadInfo() }
    }

    private func loadInfo() async {
        do { info = try await PortClient().macPortsInfo(); failure = nil }
        catch { failure = error.localizedDescription }
    }

    private func runMaintenance(
        _ title: String, name: String,
        work: @escaping @Sendable (PortClient, @escaping @MainActor @Sendable (String) -> Void) async throws -> Void
    ) {
        Task {
            await activity.run(title, name: name) { out in try await work(PortClient(), out) }
            await loadInfo()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }
}
