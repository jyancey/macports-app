import PortsKit
import SwiftUI

/// Runs `port diagnose` and lists what it finds; also launches `port reclaim`
/// in Terminal.
struct HealthView: View {
  @State private var findings: [DiagnosticFinding]?
  @State private var registryStatus: RegistryStatus?
  @State private var failure: String?
  @State private var isChecking = false
  @State private var isCheckingRegistry = false

  var body: some View {
    Form {
      Section("Environment check") {
        HStack {
          Button("Run Diagnose", systemImage: "stethoscope") { Task { await check() } }
            .disabled(isChecking)
          if isChecking { ProgressView().controlSize(.small) }
        }
        Section("Registry integrity") {
          HStack {
            Button("Check Registry", systemImage: "checkmark.shield") {
              Task { await checkRegistry() }
            }
            .disabled(isCheckingRegistry)
            if isCheckingRegistry { ProgressView().controlSize(.small) }
          }
          if let registryStatus {
            LabeledContent("Database") {
              Text(registryStatus.path).textSelection(.enabled)
                .multilineTextAlignment(.trailing)
            }
            switch registryStatus.integrity {
            case .valid:
              Label("Registry is valid.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            case .invalid(let message):
              Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
            case .unavailable(let message):
              Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            }
          } else {
            Text("Runs a read-only SQLite integrity check on the MacPorts registry.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        if let failure {
          Label(failure, systemImage: "xmark.octagon").foregroundStyle(.red)
        } else if let findings {
          if findings.isEmpty {
            Label("No problems found.", systemImage: "checkmark.circle.fill").foregroundStyle(
              .green)
          } else {
            ForEach(findings) { finding in
              Label {
                Text(finding.message).textSelection(.enabled)
              } icon: {
                Image(
                  systemName: finding.severity == .error
                    ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(finding.severity == .error ? .red : .orange)
              }
            }
          }
        } else {
          Text(
            "Checks for common problems, such as stray libraries in /usr/local that interfere with builds."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Reclaim disk space") {
        Button("Reclaim in Terminal", systemImage: "externaldrive.badge.minus") {
          Task {
            do { try await PortClient().reclaimInTerminal() } catch {
              failure = error.localizedDescription
            }
          }
        }
        Text(
          "Opens Terminal and runs sudo port reclaim. It lists inactive ports, unneeded unrequested ports "
            + "and old distfiles, and asks what to remove. Nothing is deleted until you choose."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task { if findings == nil { await check() } }
  }

  private func check() async {
    isChecking = true
    defer { isChecking = false }
    do {
      findings = try await PortClient().diagnoseFindings()
      failure = nil
    } catch { failure = error.localizedDescription }
  }

  private func checkRegistry() async {
    isCheckingRegistry = true
    defer { isCheckingRegistry = false }
    do {
      let info = try await PortClient().macPortsInfo()
      registryStatus = await PortClient().registryStatus(for: info.dataPath)
    } catch {
      registryStatus = RegistryStatus(
        path: "Unknown", exists: false, readable: false,
        integrity: .unavailable(error.localizedDescription))
    }
  }
}
