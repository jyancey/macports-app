import PortsKit
import SwiftUI

/// App preferences and facts about the local MacPorts installation.
struct ConfigurationView: View {
  @Binding private var search: String
  @Binding private var scope: SearchScope
  private let onSearch: () -> Void
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
  @State private var info: MacPortsInfo?
  @State private var failure: String?

  init(
    search: Binding<String>, scope: Binding<SearchScope>, installedCount: Int,
    onSearch: @escaping () -> Void
  ) {
    _search = search
    _scope = scope
    self.installedCount = installedCount
    self.onSearch = onSearch
  }

  var body: some View {
    Form {
      Section("Activity") {
        Toggle("Open Activity pane when a command starts", isOn: $autoOpen)
        Toggle("Verbose output", isOn: $verbose)
        Text(
          "Passes -v to port so the Activity pane shows full configure and build output. "
            + "Turn it off for faster, quieter runs."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("MacPorts") {
        pathEditor
        if let info {
          row("Version", info.version)
          row("Prefix", info.prefix)
          row("Data directory", info.dataPath)
          let registryPath = info.dataPath + "/registry/registry.db"
          row("Registry database", registryPath)
          LabeledContent("Registry status") {
            Label(
              FileManager.default.isReadableFile(atPath: registryPath) ? "Present and readable" : "Missing or unreadable",
              systemImage: FileManager.default.isReadableFile(atPath: registryPath)
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(
              FileManager.default.isReadableFile(atPath: registryPath) ? .green : .orange)
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
              }
            }
          }
        } else if let failure {
          Text(failure).foregroundStyle(.secondary)
        } else {
          ProgressView()
        }
      }
      Section("Add a source") {
        HStack {
          TextField("", text: $newSource, prompt: Text("rsync://, https://, or file:///path"))
            .textFieldStyle(.roundedBorder)
            .onSubmit(addSource)
          Button("Add", action: addSource)
            .disabled(!MacPortsInfo.isValidSourceURL(trimmedSource) || activity.isRunning)
        }
        if let sourceError {
          Label(sourceError, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
        }
        Text(
          "Adds a ports tree to sources.conf (uses macOS administrator authorization). "
            + "Local file:/// sources are searched first so they override remote ports; "
            + "run portindex in a local tree before use. Sync afterwards to fetch remote sources."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
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
      await loadInfo()
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
      ToolbarItem(placement: .primaryAction) {
        HStack(spacing: 8) {
          TextField("Search", text: $search)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .disabled(true)
            .onSubmit(onSearch)
          Menu {
            ForEach(SearchScope.allCases) { searchScope in
              Button {
                scope = searchScope
              } label: {
                if scope == searchScope {
                  Label(searchScope.rawValue, systemImage: "checkmark")
                } else {
                  Text(searchScope.rawValue)
                }
              }
            }
          } label: {
            Label(scope.rawValue, systemImage: "line.3.horizontal.decrease.circle")
          }
          .menuStyle(.borderedButton)
          .disabled(true)
        }
      }
    }
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

  private var draftProblem: String? {
    PortClient.problem(
      withExecutablePath: pathDraft.trimmingCharacters(in: .whitespacesAndNewlines))
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
            Task { await loadInfo() }
          }
          .disabled(portPath.isEmpty)
        }
      }
      if let problem = draftProblem {
        Label(problem, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.orange)
      } else {
        Text("Point this at a MacPorts installed outside /opt/local. Takes effect immediately.")
          .font(.caption).foregroundStyle(.secondary)
      }
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

  private func loadInfo() async {
    do {
      info = try await PortClient().macPortsInfo()
      failure = nil
    } catch { failure = error.localizedDescription }
  }

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
