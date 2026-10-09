import SwiftUI
import PortsKit

/// App preferences and facts about the local MacPorts installation.
struct ConfigurationView: View {
    @AppStorage(PortClient.verboseDefaultsKey) private var verbose = false
    @Environment(ActivityLog.self) private var activity
    @AppStorage(PortClient.executablePathDefaultsKey) private var portPath = ""
    @State private var pathDraft = ""
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
                pathEditor
                if let info {
                    row("Version", info.version)
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
        .task {
            pathDraft = PortClient.configuredExecutablePath
            await loadInfo()
        }
    }

    private var draftProblem: String? {
        PortClient.problem(withExecutablePath: pathDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var pathEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("port executable") {
                HStack {
                    TextField("", text: $pathDraft, prompt: Text(PortClient.defaultExecutablePath))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(applyPath)
                    Button("Choose…", action: choosePath)
                    Button("Apply", action: applyPath)
                        .disabled(draftProblem != nil
                                  || pathDraft.trimmingCharacters(in: .whitespacesAndNewlines) == PortClient.configuredExecutablePath)
                    Button("Reset") {
                        portPath = ""
                        pathDraft = PortClient.defaultExecutablePath
                        Task { await loadInfo() }
                    }
                    .disabled(portPath.isEmpty)
                }
            }
            if let problem = draftProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Point this at a MacPorts installed outside /opt/local. Takes effect immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func applyPath() {
        let value = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PortClient.problem(withExecutablePath: value) == nil else { return }
        portPath = value == PortClient.defaultExecutablePath ? "" : value
        Task { await loadInfo() }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the MacPorts port executable"
        if panel.runModal() == .OK, let url = panel.url { pathDraft = url.path }
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
