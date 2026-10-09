import SwiftUI
import PortsKit

/// App preferences. Add a control here for each new setting.
struct ConfigurationView: View {
    @AppStorage(PortClient.verboseDefaultsKey) private var verbose = false

    var body: some View {
        Form {
            Section("Activity") {
                Toggle("Verbose output", isOn: $verbose)
                Text("Passes -v to port so the Activity pane shows full configure and build output. "
                     + "Turn it off for faster, quieter runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
