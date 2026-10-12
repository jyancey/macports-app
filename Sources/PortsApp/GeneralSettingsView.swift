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
      Section("MacPorts location") {
        pathEditor
      }
    }
    .formStyle(.grouped)
    .task { pathDraft = PortClient.configuredExecutablePath }
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
