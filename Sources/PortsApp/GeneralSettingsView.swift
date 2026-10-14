// GeneralSettingsView.swift - General settings pane: Activity pane preferences and the port executable path.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import AppKit
import PortsKit
import SwiftUI

/// Activity pane preferences and where the `port` executable lives.
struct GeneralSettingsView: View {
  @AppStorage(PortClient.verboseDefaultsKey) private var verbose = false
  @AppStorage(ActivityLog.autoOpenKey) private var autoOpen = true
  @AppStorage(PortClient.executablePathDefaultsKey) private var portPath = ""
  @AppStorage(UpdateNotifier.badgeKey) private var showBadge = true
  @AppStorage(UpdateNotifier.notifyKey) private var notifyOnUpdates = false
  @Environment(AppUpdateModel.self) private var appUpdates
  @AppStorage(AppUpdateModel.autoCheckKey) private var autoCheckApp = true
  @AppStorage(AppUpdateModel.prereleasesKey) private var includePrereleases = false
  @State private var pathDraft = ""
  /// What's wrong with the typed `port` path; updated when it changes rather
  /// than checking the disk on every redraw.
  @State private var draftProblem: String?
  /// Reread after the path changes, so the MacPorts and Health panes follow it.
  let configuration: ConfigurationModel

  var body: some View {
    Form {
      Section {
        Toggle("Open Activity pane when a command starts", isOn: $autoOpen)
        Toggle("Verbose output", isOn: $verbose)
      } header: {
        Text("Activity")
      } footer: {
        Text(
          "Verbose output passes -v to port so the Activity pane shows full configure and build "
            + "output. Turn it off for faster, quieter runs.")
      }
      Section {
        Toggle("Show the number of outdated ports on the Dock icon", isOn: $showBadge)
        Toggle("Notify when a sync finds new updates", isOn: $notifyOnUpdates)
      } header: {
        Text("Updates")
      } footer: {
        Text(
          "The count is refreshed after every sync and upgrade. Notifications need permission "
            + "from macOS and work in the packaged app.")
      }
      Section {
        Toggle("Check for new versions of \(AppInfo.name) daily", isOn: $autoCheckApp)
        Toggle("Include pre-releases", isOn: $includePrereleases)
        HStack {
          Button("Check Now") {
            Task {
              appUpdates.clearSkipped()
              await appUpdates.check()
            }
          }
          .disabled(appUpdates.isChecking)
          if appUpdates.isChecking { ProgressView().controlSize(.small) }
          Text(appUpdateStatus).foregroundStyle(.secondary)
        }
      } header: {
        Text("\(AppInfo.name) updates")
      } footer: {
        Text(
          "Looks for new releases on GitHub. Updates are not installed automatically: "
            + "View Release opens the download page.")
      }
      Section("MacPorts location") {
        pathEditor
      }
    }
    .formStyle(.grouped)
    .task { pathDraft = PortClient.configuredExecutablePath }
    .onChange(of: showBadge) {
      UpdateNotifier.shared.updateBadge(count: UpdateNotifier.shared.lastCount)
    }
    .onChange(of: notifyOnUpdates) { if notifyOnUpdates { UpdateNotifier.requestAuthorization() } }
    .onChange(of: includePrereleases) { Task { await appUpdates.check() } }
  }

  private var appUpdateStatus: String {
    switch appUpdates.outcome {
    case nil: "Version \(appUpdates.currentVersion)"
    case .upToDate?: "Up to date (version \(appUpdates.currentVersion))"
    case .updateAvailable(let release)?: "\(release.tag) is available"
    case .failed(let message)?: message
    }
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
            .disabled(
              draftProblem != nil
                || pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                  == PortClient.configuredExecutablePath
            )
          Button("Reset") {
            portPath = ""
            pathDraft = PortClient.defaultExecutablePath
            Task { await configuration.load() }
          }
          .disabled(portPath.isEmpty)
        }
      }
      if let problem = draftProblem {
        StatusLabel(problem, systemImage: "exclamationmark.triangle.fill", color: .orange)
          .font(.caption)
      } else {
        Text("Point this at a MacPorts installed outside /opt/local. Takes effect immediately.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .onChange(of: pathDraft, initial: true) {
      draftProblem = PortClient.problem(
        withExecutablePath: pathDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  private func applyPath() {
    let value = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard PortClient.problem(withExecutablePath: value) == nil else { return }
    portPath = value == PortClient.defaultExecutablePath ? "" : value
    Task { await configuration.load() }
  }

  private func choosePath() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose the MacPorts port executable"
    if panel.runModal() == .OK, let url = panel.url { pathDraft = url.path }
  }
}
