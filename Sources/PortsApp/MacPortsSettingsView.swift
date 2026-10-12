// MacPortsSettingsView.swift - MacPorts settings pane: installation facts, self-update and sync, and sources.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import PortsKit
import SwiftUI

/// MacPorts facts for the Settings window. Owned by the app so they survive
/// closing Settings; reloaded when stale or after a command.
@MainActor
@Observable
final class ConfigurationModel {
  private(set) var info: MacPortsInfo?
  private(set) var failure: String?
  /// Whether the registry database can be read; checked once per load rather
  /// than on every redraw.
  private(set) var registryReadable = false

  typealias Fetch = @Sendable () async throws -> MacPortsInfo
  private let fetch: Fetch
  @ObservationIgnored private var freshness = Freshness()

  /// The default reads the configured `port` path on each load, so a new path
  /// takes effect immediately.
  init(fetch: @escaping Fetch = { try await PortClient().macPortsInfo() }) {
    self.fetch = fetch
  }

  /// Loads unless the facts were loaded recently and nothing has changed since.
  func loadIfStale() async {
    if freshness.isStale { await load() }
  }

  /// Marks the facts out of date, such as after a command changed the system.
  func invalidate() { freshness.invalidate() }

  func load() async {
    let token = freshness.begin()
    do {
      let loaded = try await fetch()
      info = loaded
      registryReadable = FileManager.default.isReadableFile(atPath: loaded.registryPath)
      failure = nil
      freshness.markLoaded(token)
    } catch is CancellationError {
      // Closing the pane cancels the load; keep what was there.
    } catch {
      failure = error.localizedDescription
    }
  }
}

/// `port selfupdate` and `port sync`, offered in the MacPorts menu and the
/// MacPorts settings pane.
enum MacPortsMaintenance: CaseIterable {
  case selfupdate
  case sync

  var title: String {
    switch self {
    case .selfupdate: "Self-update"
    case .sync: "Sync"
    }
  }

  var systemImage: String {
    switch self {
    case .selfupdate: "arrow.triangle.2.circlepath"
    case .sync: "arrow.down.circle"
    }
  }

  var help: String {
    switch self {
    case .selfupdate: "Upgrade MacPorts and refresh the ports tree"
    case .sync: "Refresh the ports tree without upgrading MacPorts"
    }
  }

  /// Runs the command in the Activity log, then rereads the MacPorts facts.
  @MainActor
  func run(activity: ActivityLog, configuration: ConfigurationModel) {
    Task {
      switch self {
      case .selfupdate:
        await activity.run("sudo port selfupdate", name: "selfupdate") { out in
          try await PortClient().selfupdate(onOutput: out)
        }
      case .sync:
        await activity.run("sudo port sync", name: "sync") { out in
          try await PortClient().sync(onOutput: out)
        }
      }
      await configuration.load()
    }
  }
}

/// Facts about the local MacPorts installation, its sources, and updating it.
struct MacPortsSettingsView: View {
  @Environment(ActivityLog.self) private var activity
  @State private var newSource = ""
  @State private var sourceError: String?
  @State private var sourceToRemove: String?
  let model: ConfigurationModel
  private var info: MacPortsInfo? { model.info }

  var body: some View {
    Form {
      Section("MacPorts") {
        if let info {
          row("Version", info.version)
          row("Prefix", info.prefix)
          row("Data directory", info.dataPath)
          row("Registry database", info.registryPath)
          row("Applications", info.applicationsDir)
          row(
            "Last sync", info.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
          )
        } else if let failure = model.failure {
          Text(failure).foregroundStyle(.secondary)
        } else {
          ProgressView("Reading MacPorts settings…")
        }
      }
      Section {
        HStack {
          ForEach(MacPortsMaintenance.allCases, id: \.self) { task in
            Button(task.title, systemImage: task.systemImage) {
              task.run(activity: activity, configuration: model)
            }
            .help(task.help)
          }
        }
        .disabled(activity.isRunning)
      } header: {
        Text("Update")
      } footer: {
        Text(
          "Self-update upgrades MacPorts itself and refreshes the ports tree; Sync only refreshes "
            + "the ports tree. Output appears in the main window's Activity pane.")
      }
      if let info {
        Section("Sources") {
          ForEach(info.sources, id: \.self) { src in
            HStack {
              Text(src).textSelection(.enabled)
              Spacer()
              Button("Remove source", systemImage: "minus.circle") { sourceToRemove = src }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(info.sources.count < 2 || activity.isRunning)
                .help(removeSourceHelp(sourceCount: info.sources.count))
            }
          }
        }
      }
      Section {
        HStack {
          TextField("", text: $newSource, prompt: Text("rsync://, https://, or file:///path"))
            .textFieldStyle(.roundedBorder)
            .onSubmit(addSource)
          Button("Add", action: addSource)
            .disabled(!MacPortsInfo.isValidSourceURL(trimmedSource) || activity.isRunning)
        }
        if let sourceError {
          StatusLabel(sourceError, systemImage: "exclamationmark.triangle.fill", color: .orange)
            .font(.caption)
        }
      } header: {
        Text("Add a source")
      } footer: {
        Text(
          "Adds a ports tree to sources.conf (uses macOS administrator authorization). "
            + "Local file:/// sources are searched first so they override remote ports; "
            + "run portindex in a local tree before use. Sync afterwards to fetch remote sources.")
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Remove this source?",
      isPresented: Binding(
        get: { sourceToRemove != nil }, set: { if !$0 { sourceToRemove = nil } }),
      presenting: sourceToRemove
    ) { url in
      Button("Remove", role: .destructive) { removeSource(url) }
    } message: { url in
      Text(
        "\(url) will be removed from sources.conf. macOS administrator authorization will be requested."
      )
    }
    .task { await model.loadIfStale() }
  }

  private func removeSourceHelp(sourceCount: Int) -> String {
    if sourceCount < 2 { return "The last source can't be removed" }
    if activity.isRunning { return "Wait for the running command to finish" }
    return "Remove this source from sources.conf"
  }

  private var trimmedSource: String { newSource.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func removeSource(_ url: String) {
    guard let conf = info?.sourcesConfPath else { return }
    sourceError = nil
    Task {
      await activity.run("remove source \(url)", name: "sources") { out in
        try await PortClient().removeSource(url, from: conf)
        out("Removed \(url) from \(conf)\n")
      }
      await model.load()
      if info?.sources.contains(url) == true { sourceError = "The source was not removed." }
    }
  }

  private func addSource() {
    let url = trimmedSource
    guard MacPortsInfo.isValidSourceURL(url), let conf = info?.sourcesConfPath else { return }
    sourceError = nil
    Task {
      await activity.run("add source \(url)", name: "sources") { out in
        try await PortClient().addSource(url, to: conf)
        out("Added \(url) to \(conf)\n")
      }
      await model.load()
      if info?.sources.contains(url) == true {
        newSource = ""
      } else {
        sourceError = "The source was not added."
      }
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    LabeledContent(label) {
      Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
    }
  }
}
