import PortsKit
import SwiftUI

/// Health tab results. Owned by `ContentView` so they survive switching tabs:
/// `port diagnose` takes seconds, so it runs once on the first visit and then
/// only when asked.
@MainActor
@Observable
final class HealthModel {
  private(set) var findings: [DiagnosticFinding]?
  private(set) var registryStatus: RegistryStatus?
  var failure: String?
  private(set) var isChecking = false
  private(set) var isCheckingRegistry = false

  typealias Diagnose = @Sendable () async throws -> [DiagnosticFinding]
  private let diagnose: Diagnose

  init(diagnose: @escaping Diagnose = { try await PortClient().diagnoseFindings() }) {
    self.diagnose = diagnose
  }

  /// Runs the check unless it has already run (or is running).
  func checkIfNeeded() async {
    guard findings == nil, failure == nil, !isChecking else { return }
    await check()
  }

  func check() async {
    isChecking = true
    defer { isChecking = false }
    do {
      findings = try await diagnose()
      failure = nil
    } catch is CancellationError {
      // Leaving the tab cancels the first check; the next visit runs it again.
    } catch {
      failure = error.localizedDescription
    }
  }

  func checkRegistry() async {
    isCheckingRegistry = true
    defer { isCheckingRegistry = false }
    registryStatus = await PortClient().registryStatus()
  }
}

/// Runs `port diagnose` and lists what it finds; also launches `port reclaim`
/// in Terminal.
struct HealthView: View {
  let model: HealthModel

  var body: some View {
    Form {
      Section("Environment check") {
        HStack {
          Button("Run Diagnose", systemImage: "stethoscope") { Task { await model.check() } }
            .disabled(model.isChecking)
          if model.isChecking { ProgressView().controlSize(.small) }
        }
        Section("Registry integrity") {
          HStack {
            Button("Check Registry", systemImage: "checkmark.shield") {
              Task { await model.checkRegistry() }
            }
            .disabled(model.isCheckingRegistry)
            if model.isCheckingRegistry { ProgressView().controlSize(.small) }
          }
          if let registryStatus = model.registryStatus {
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
        if let failure = model.failure {
          Label(failure, systemImage: "xmark.octagon").foregroundStyle(.red)
        } else if let findings = model.findings {
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
              model.failure = error.localizedDescription
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
    .task { await model.checkIfNeeded() }
  }
}
