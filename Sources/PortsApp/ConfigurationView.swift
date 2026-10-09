import SwiftUI
import PortsKit

/// App preferences and facts about the local MacPorts installation.
struct ConfigurationView: View {
    @AppStorage(PortClient.verboseDefaultsKey) private var verbose = false
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
        }
        .formStyle(.grouped)
        .task {
            do { info = try await PortClient().macPortsInfo() }
            catch { failure = error.localizedDescription }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }
}
