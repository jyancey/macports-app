import PortsKit
import SwiftUI

/// MacPorts facts for the Configuration tab. Owned by `ContentView` so they
/// survive switching tabs; reloaded when stale or after a command.
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
      // Leaving the tab cancels the load; keep what was there.
    } catch {
      failure = error.localizedDescription
    }
  }
}

/// App preferences and facts about the local MacPorts installation.
struct ConfigurationView: View {
  /// From the Installed list, so showing this tab doesn't run `port installed`.
  private let installedCount: Int
  @AppStorage(PortClient.verboseDefaultsKey) private var verbose = false
  @AppStorage(ActivityLog.autoOpenKey) private var autoOpen = true
  @Environment(ActivityLog.self) private var activity
  @AppStorage(PortClient.executablePathDefaultsKey) private var portPath = ""
  @State private var pathDraft = ""
  @State private var newSource = ""
  @State private var sourceError: String?
  @State private var sourceToRemove: String?
  private let model: ConfigurationModel
  private var info: MacPortsInfo? { model.info }
  private var failure: String? { model.failure }

  init(model: ConfigurationModel, installedCount: Int) {
    self.model = model
    self.installedCount = installedCount
  }

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
      Section("MacPorts") {
        pathEditor
        if let info {
          row("Version", info.version)
          row("Prefix", info.prefix)
          row("Data directory", info.dataPath)
          row("Registry database", info.registryPath)
          LabeledContent("Registry status") {
            if model.registryReadable {
              StatusLabel(
                "Present and readable", systemImage: "checkmark.circle.fill", color: .green)
            } else {
              StatusLabel(
                "Missing or unreadable", systemImage: "exclamationmark.triangle.fill",
                color: .orange)
            }
          }
          row("Applications", info.applicationsDir)
          row("Installed ports", "\(installedCount)")
          row(
            "Last sync", info.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
          )
          ForEach(Array(info.sources.enumerated()), id: \.offset) { i, src in
            LabeledContent(i == 0 ? "Sources" : "") {
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
        } else if let failure {
          Text(failure).foregroundStyle(.secondary)
        } else {
          ProgressView("Reading MacPorts settings…")
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
    .task {
      pathDraft = PortClient.configuredExecutablePath
      await model.loadIfStale()
    }
    .toolbar {
      ToolbarItemGroup {
        Button("Self-update", systemImage: "arrow.triangle.2.circlepath") {
          runMaintenance("sudo port selfupdate", name: "selfupdate") {
            try await $0.selfupdate(onOutput: $1)
          }
        }
        .help("Upgrade MacPorts and refresh the ports tree")
        .disabled(activity.isRunning)
        Button("Sync", systemImage: "arrow.down.circle") {
          runMaintenance("sudo port sync", name: "sync") { try await $0.sync(onOutput: $1) }
        }
        .help("Refresh the ports tree without upgrading MacPorts")
        .disabled(activity.isRunning)
      }
    }
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
      await loadInfo()
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
      await loadInfo()
      if info?.sources.contains(url) == true {
        newSource = ""
      } else {
        sourceError = "The source was not added."
      }
    }
  }

  /// What's wrong with the typed `port` path; updated when it changes rather
  /// than checking the disk on every redraw.
  @State private var draftProblem: String?

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
            Task { await loadInfo() }
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

  private func loadInfo() async { await model.load() }

  private func runMaintenance(
    _ title: String, name: String,
    work:
      @escaping @Sendable (PortClient, @escaping @MainActor @Sendable (String) -> Void) async throws
      -> Void
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
