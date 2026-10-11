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
  private(set) var failure: String?
  /// Why Terminal couldn't be opened for `port reclaim`.
  private(set) var reclaimFailure: String?
  private(set) var isChecking = false
  private(set) var isCheckingRegistry = false

  typealias Diagnose = @Sendable () async throws -> [DiagnosticFinding]
  typealias Reclaim = @Sendable () async throws -> Void
  private let diagnose: Diagnose
  private let reclaim: Reclaim

  init(
    diagnose: @escaping Diagnose = { try await PortClient().diagnoseFindings() },
    reclaim: @escaping Reclaim = { try await PortClient().reclaimInTerminal() }
  ) {
    self.diagnose = diagnose
    self.reclaim = reclaim
  }

  /// Errors first, then warnings, otherwise in the order `port` reported them.
  var sortedFindings: [DiagnosticFinding] {
    let list = findings ?? []
    return list.filter { $0.severity == .error } + list.filter { $0.severity != .error }
  }

  /// "1 error, 2 warnings"; nil before a check or when nothing was found.
  var summary: String? {
    let list = findings ?? []
    let errors = list.filter { $0.severity == .error }.count
    let warnings = list.count - errors
    var parts: [String] = []
    if errors > 0 { parts.append(errors == 1 ? "1 error" : "\(errors) errors") }
    if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
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

  func reclaimInTerminal() async {
    reclaimFailure = nil
    do { try await reclaim() } catch { reclaimFailure = error.localizedDescription }
  }
}

/// Runs `port diagnose` and lists what it finds, checks the registry, and
/// launches `port reclaim` in Terminal.
struct HealthView: View {
  let model: HealthModel

  var body: some View {
    Form {
      Section {
        HStack {
          Button("Run Diagnose", systemImage: "stethoscope") { Task { await model.check() } }
            .disabled(model.isChecking)
          if model.isChecking {
            ProgressView().controlSize(.small).accessibilityLabel("Checking")
          }
        }
        diagnoseResults
      } header: {
        HStack {
          Text("Environment check")
          Spacer()
          if let summary = model.summary { Text(summary).foregroundStyle(.secondary) }
        }
      } footer: {
        if model.findings == nil && model.failure == nil {
          Text(
            "Checks for common problems, such as stray libraries in /usr/local that interfere with builds."
          )
        }
      }

      Section {
        HStack {
          Button("Check Registry", systemImage: "checkmark.shield") {
            Task { await model.checkRegistry() }
          }
          .disabled(model.isCheckingRegistry)
          if model.isCheckingRegistry {
            ProgressView().controlSize(.small).accessibilityLabel("Checking the registry")
          }
        }
        if let registryStatus = model.registryStatus {
          LabeledContent("Database") {
            Text(registryStatus.path).textSelection(.enabled)
              .multilineTextAlignment(.trailing)
          }
          switch registryStatus.integrity {
          case .valid:
            StatusLabel("Registry is valid.", systemImage: "checkmark.circle.fill", color: .green)
          case .invalid(let message):
            StatusLabel(message, systemImage: "xmark.octagon.fill", color: .red)
          case .unavailable(let message):
            StatusLabel(message, systemImage: "exclamationmark.triangle.fill", color: .orange)
          }
        }
      } header: {
        Text("Registry integrity")
      } footer: {
        if model.registryStatus == nil {
          Text("Runs a read-only SQLite integrity check on the MacPorts registry.")
        }
      }

      Section {
        Button("Reclaim in Terminal", systemImage: "externaldrive.badge.minus") {
          Task { await model.reclaimInTerminal() }
        }
        if let reclaimFailure = model.reclaimFailure {
          StatusLabel(reclaimFailure, systemImage: "xmark.octagon.fill", color: .red)
        }
      } header: {
        Text("Reclaim disk space")
      } footer: {
        Text(
          "Opens Terminal and runs sudo port reclaim. It lists inactive ports, unneeded unrequested ports "
            + "and old distfiles, and asks what to remove. Nothing is deleted until you choose."
        )
      }
    }
    .formStyle(.grouped)
    .task { await model.checkIfNeeded() }
  }

  @ViewBuilder private var diagnoseResults: some View {
    if let failure = model.failure {
      StatusLabel(failure, systemImage: "xmark.octagon.fill", color: .red)
    } else if let findings = model.findings {
      if findings.isEmpty {
        StatusLabel("No problems found.", systemImage: "checkmark.circle.fill", color: .green)
      } else {
        ForEach(model.sortedFindings) { finding in
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
    }
  }
}
