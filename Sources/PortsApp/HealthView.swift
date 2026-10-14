// HealthView.swift - Health settings pane: port diagnose, registry integrity, and port reclaim.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import PortsKit
import SwiftUI

/// Health pane results. Owned by the app so they survive closing Settings:
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
  typealias CleanAll = @Sendable (@escaping @MainActor @Sendable (String) -> Void) async throws
    -> Void
  private let diagnose: Diagnose
  private let reclaim: Reclaim
  private let cleanAllPorts: CleanAll

  init(
    diagnose: @escaping Diagnose = { try await PortClient().diagnoseFindings() },
    reclaim: @escaping Reclaim = { try await PortClient().reclaimInTerminal() },
    cleanAll: @escaping CleanAll = { try await PortClient().cleanAll(onOutput: $0) }
  ) {
    self.diagnose = diagnose
    self.reclaim = reclaim
    self.cleanAllPorts = cleanAll
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
      // Leaving the pane cancels the first check; the next visit runs it again.
    } catch {
      failure = error.localizedDescription
    }
  }

  func checkRegistry() async {
    isCheckingRegistry = true
    defer { isCheckingRegistry = false }
    registryStatus = await PortClient().registryStatus()
  }

  /// Deletes build leftovers of every installed port, through the Activity
  /// log. Does nothing while another command is running.
  func cleanAll(activity: ActivityLog) async {
    guard !activity.isRunning else { return }
    let clean = cleanAllPorts
    await activity.run("sudo port clean --all installed", name: "clean") { out in
      try await clean(out)
    }
  }

  func reclaimInTerminal() async {
    reclaimFailure = nil
    do { try await reclaim() } catch { reclaimFailure = error.localizedDescription }
  }
}

/// Runs `port diagnose` and lists what it finds, checks the registry, and
/// launches `port reclaim` in Terminal.
struct HealthView: View {
  @Environment(ActivityLog.self) private var activity
  let model: HealthModel
  /// Where the registry is and whether it can be read, shown before the
  /// integrity check has run.
  let configuration: ConfigurationModel

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
        } else if let info = configuration.info {
          LabeledContent("Database") {
            Text(info.registryPath).textSelection(.enabled)
              .multilineTextAlignment(.trailing)
          }
          if configuration.registryReadable {
            StatusLabel(
              "Present and readable.", systemImage: "checkmark.circle.fill", color: .green)
          } else {
            StatusLabel(
              "Missing or unreadable.", systemImage: "exclamationmark.triangle.fill", color: .orange
            )
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
        Button("Clean All Build Files", systemImage: "sparkles") {
          Task { await model.cleanAll(activity: activity) }
        }
        .disabled(activity.isRunning)
        .help("Run port clean --all on every installed port")
        if let reclaimFailure = model.reclaimFailure {
          StatusLabel(reclaimFailure, systemImage: "xmark.octagon.fill", color: .red)
        }
      } header: {
        Text("Reclaim disk space")
      } footer: {
        Text(
          "Reclaim opens Terminal and runs sudo port reclaim. It lists inactive ports, unneeded unrequested ports "
            + "and old distfiles, and asks what to remove. Nothing is deleted until you choose. "
            + "Clean All Build Files deletes the work directories, downloaded distfiles and logs of every "
            + "installed port; installed software is not touched."
        )
      }
    }
    .formStyle(.grouped)
    .task { await model.checkIfNeeded() }
    .task { await configuration.loadIfStale() }
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
