import PortsKit
import SwiftUI

@MainActor
@Observable
final class InstalledPortsModel {
  var ports: [InstalledPort] = []
  var isLoading = false
  var errorMessage: String?

  private let client = PortClient()

  func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      ports = try await client.installedPorts()
    } catch {
      ports = []
      errorMessage = error.localizedDescription
    }
  }
}

@MainActor
@Observable
final class SearchModel {
  var results: [String] = []
  var isSearching = false
  var errorMessage: String?
  var hasSearched = false
  /// Pre-built binary hints for the current results; a missing key means
  /// not checked yet.
  private(set) var binary: [String: BinaryAvailability] = [:]
  private var binaryTask: Task<Void, Never>?

  typealias Search = @Sendable (_ term: String, _ scope: SearchScope) async throws -> [String]
  typealias BinaryHint = @Sendable (_ name: String) async -> BinaryAvailability

  private let runSearch: Search
  private let binaryHint: BinaryHint
  private static let binaryCheckLimit = 100

  /// Defaults run `port search` and query the archive site; tests substitute their own.
  init(
    search: @escaping Search = { [client = PortClient()] term, scope in
      try await client.search(term, scope: scope)
    },
    binaryHint: @escaping BinaryHint = BinaryArchive.anyBuildAvailability
  ) {
    runSearch = search
    self.binaryHint = binaryHint
  }

  func binaryCheckPending(_ name: String) -> Bool {
    results.prefix(Self.binaryCheckLimit).contains(name)
  }

  private func checkBinaries(_ names: [String]) {
    binaryTask?.cancel()
    binary = [:]
    let binaryHint = self.binaryHint
    binaryTask = Task {
      let batch = Array(names.prefix(Self.binaryCheckLimit))
      await withTaskGroup(of: (String, BinaryAvailability).self) { group in
        var iterator = batch.makeIterator()
        func addNext() {
          if let name = iterator.next() {
            group.addTask { (name, await binaryHint(name)) }
          }
        }
        for _ in 0..<6 { addNext() }
        while let (name, result) = await group.next() {
          if Task.isCancelled {
            group.cancelAll()
            return
          }
          binary[name] = result
          addNext()
        }
      }
    }
  }

  /// Starts a search, cancelling (and terminating) any search still running so
  /// an older, slower one can't replace the newer results.
  func search(_ term: String, scope: SearchScope) {
    searchTask?.cancel()
    searchTask = Task { await performSearch(term, scope: scope) }
  }

  private var searchTask: Task<Void, Never>?

  private func performSearch(_ term: String, scope: SearchScope) async {
    isSearching = true
    errorMessage = nil
    do {
      let found = try await runSearch(term, scope)
      guard !Task.isCancelled else { return }
      results = found
      hasSearched = true
      checkBinaries(found)
    } catch {
      // A cancelled search was replaced by a newer one, which owns the state.
      guard !Task.isCancelled, !(error is CancellationError) else { return }
      results = []
      errorMessage = error.localizedDescription
    }
    isSearching = false
  }
}

@MainActor
@Observable
final class SelectionsModel {
  var groups: [PortSelectGroup] = []
  var isLoading = false
  var errorMessage: String?

  func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      groups = try await PortClient().selections()
    } catch {
      groups = []
      errorMessage = error.localizedDescription
    }
  }
}

@MainActor
@Observable
final class OutdatedModel {
  var ports: [OutdatedPort] = []
  var isLoading = false
  var errorMessage: String?
  /// Whether the new version is available pre-built (with the installed
  /// variants); missing means not checked yet.
  private(set) var binary: [String: BinaryAvailability] = [:]
  private var binaryTask: Task<Void, Never>?

  private let client = PortClient()

  func checkBinaries(installed: [InstalledPort]) {
    binaryTask?.cancel()
    binary = [:]
    let variants = Dictionary(
      installed.filter(\.isActive).map { ($0.name, $0.variants) },
      uniquingKeysWith: { first, _ in first })
    let batch = ports
    binaryTask = Task {
      await withTaskGroup(of: (String, BinaryAvailability).self) { group in
        var iterator = batch.makeIterator()
        func addNext() {
          guard let port = iterator.next() else { return }
          let parts = port.availableVersion.split(separator: "_", maxSplits: 1)
          let version = parts.first.map(String.init) ?? port.availableVersion
          let revision = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
          let wanted = variants[port.name] ?? []
          group.addTask {
            (
              port.name,
              await BinaryArchive.availability(
                name: port.name, version: version, revision: revision, variants: wanted)
            )
          }
        }
        for _ in 0..<6 { addNext() }
        while let (name, result) = await group.next() {
          if Task.isCancelled {
            group.cancelAll()
            return
          }
          binary[name] = result
          addNext()
        }
      }
    }
  }

  func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      ports = try await client.outdated()
    } catch {
      ports = []
      errorMessage = error.localizedDescription
    }
  }
}

/// Sidebar destinations. Add a case here to add a tab.
enum BrowseMode: String, CaseIterable, Identifiable {
  case installed = "Installed"
  case available = "Available"
  case outdated = "Outdated"
  case inactive = "Inactive"
  case
    selections = "Selections"
  case health = "Health"
  case configuration = "Configuration"
  var id: Self { self }

  var symbol: String {
    switch self {
    case .installed: "checkmark.circle"
    case .available: "magnifyingglass"
    case .outdated: "arrow.triangle.2.circlepath"
    case .inactive: "archivebox"
    case .selections: "arrow.left.arrow.right.circle"
    case .health: "stethoscope"
    case .configuration: "gearshape"
    }
  }
}

struct SearchRow: Identifiable {
  let name: String
  let isInstalled: Bool
  var id: String { name }
}

struct ContentView: View {
  @Environment(ActivityLog.self) private var activity
  @State private var model = InstalledPortsModel()
  @State private var searchModel = SearchModel()
  @State private var outdatedModel = OutdatedModel()
  @State private var outdatedSelection: String?
  @State private var inactiveSelection: InstalledPort.ID?
  @State private var selectionsModel = SelectionsModel()
  @State private var groupSelection: String?
  @State private var mode: BrowseMode? = .installed
  @State private var searchSelection: String?
  @State private var search = ""
  @State private var scope = SearchScope.name
  @State private var prebuiltOnly = false
  @State private var sortOrder = [KeyPathComparator(\InstalledPort.name)]

  @State private var selection: InstalledPort.ID?

  private var filtered: [InstalledPort] {
    let matches =
      search.isEmpty
      ? model.ports
      : model.ports.filter { $0.name.localizedCaseInsensitiveContains(search) }
    return matches.sorted(using: sortOrder)
  }

  private var selectedPort: InstalledPort? {
    model.ports.first { $0.id == selection }
  }

  private var inactivePorts: [InstalledPort] {
    let matches = model.ports.filter { !$0.isActive }
    let shown =
      search.isEmpty ? matches : matches.filter { $0.name.localizedCaseInsensitiveContains(search) }
    return shown.sorted(using: sortOrder)
  }

  @AppStorage("activityHeight") private var activityHeight: Double = 200
  @State private var dragPreview: Double?
  @State private var isSidebarVisible = true

  private var currentMode: BrowseMode { mode ?? .installed }
  private var isSinglePaneMode: Bool {
    currentMode == .health || currentMode == .configuration
  }

  var body: some View {
    split
    .task { await model.load() }
    .task(id: outdatedModel.ports.map(\.availableVersion) + [String(model.ports.count)]) {
      outdatedModel.checkBinaries(installed: model.ports)
    }
    .task(id: mode) {
      if !searchIsEnabled { search = "" }
      if currentMode == .outdated { await outdatedModel.load() }
      if currentMode == .selections { await selectionsModel.load() }
    }
  }

  private func refreshAll() async {
    await model.load()
    await outdatedModel.load()
    if currentMode == .selections { await selectionsModel.load() }
  }

  private var upgradeAllButton: some View {
    Button("Upgrade All", systemImage: "desktopcomputer.and.arrow.down") {
      Task {
        await activity.run("sudo port upgrade outdated", name: "outdated") { out in
          try await PortClient().upgradeAll(onOutput: out)
        }
        await refreshAll()
      }
    }
    .disabled(activity.isRunning || outdatedModel.ports.isEmpty)
    .help("Upgrade every outdated port")
  }

  private var removeInactiveButtons: some View {
    Group {
      Button("Remove Selected", systemImage: "eraser.badge.xmark") {
        guard let port = model.ports.first(where: { $0.id == inactiveSelection }) else { return }
        Task {
          _ = await activity.run(
            "sudo port uninstall \(port.name) @\(port.version)_\(port.revision)",
            name: port.name
          ) { out in
            try await PortClient().uninstall(port, onOutput: out)
          }
          inactiveSelection = nil
          await model.load()
        }
      }
      .disabled(activity.isRunning || inactiveSelection == nil)
      .help("Remove the selected inactive version")
      Button("Remove All", systemImage: "eraser.badge.xmark.fill") {
        Task {
          _ = await activity.run("sudo port uninstall inactive", name: "inactive") { out in
            try await PortClient().uninstallInactive(onOutput: out)
          }
          inactiveSelection = nil
          await model.load()
        }
      }
      .disabled(activity.isRunning || model.ports.allSatisfy(\.isActive))
      .help("Remove every inactive version")
    }
  }

  /// Jumps to a port: the Installed tab if it's installed, otherwise Available.
  private func openPort(_ name: String) {
    if let port = model.ports.first(where: { $0.name == name && $0.isActive })
      ?? model.ports.first(where: { $0.name == name })
    {
      mode = .installed
      selection = port.id
    } else {
      mode = .available
      searchSelection = name
    }
  }

  private var split: some View {
    HStack(spacing: 0) {
      if isSidebarVisible {
        VStack(spacing: 0) {
          List(BrowseMode.allCases, selection: $mode) { item in
            Label(item.rawValue, systemImage: item.symbol).tag(item)
          }
          .listStyle(.sidebar)
        }
        .frame(minWidth: 150, idealWidth: 170, maxWidth: 220)

        Divider()
      }

      VStack(spacing: 0) {
        Group {
          if isSinglePaneMode {
            mainPane
          } else {
            HStack(spacing: 0) {
              mainPane
                .frame(minWidth: 380, idealWidth: 460, maxHeight: .infinity)

              Divider()

              detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if activity.isVisible {
          activityPane
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .toolbar {
      ToolbarItem {
        Button(
          isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
          systemImage: "sidebar.left")
        {
          isSidebarVisible.toggle()
        }
        .help(isSidebarVisible ? "Hide the navigation sidebar" : "Show the navigation sidebar")
      }
      ToolbarItem {
        Button("Activity Log", systemImage: "terminal") { activity.isVisible.toggle() }
          .help("Show or hide the activity log")
      }
      if currentMode == .available {
        ToolbarItem {
          Toggle("Pre-built only", systemImage: "checkmark.seal", isOn: $prebuiltOnly)
            .help(
              "Show only results that have a pre-built binary for this Mac (first 100 results are checked)"
            )
        }
      }
      if currentMode == .outdated {
        ToolbarItem {
          Toggle("Pre-built only", systemImage: "checkmark.seal", isOn: $prebuiltOnly)
            .help("Show only updates that have a pre-built binary for this Mac")
        }
        ToolbarItem { upgradeAllButton }
      }
      if currentMode == .inactive { ToolbarItemGroup { removeInactiveButtons } }
      ToolbarItem {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshAll() } }
          .disabled(model.isLoading || outdatedModel.isLoading)
      }
      if currentMode != .configuration {
        ToolbarItem(placement: .primaryAction) {
        HStack(spacing: 8) {
          TextField(searchPrompt, text: $search)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .disabled(!searchIsEnabled)
            .onSubmit {
              guard currentMode == .available else { return }
              searchModel.search(search, scope: scope)
            }
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
          .disabled(currentMode != .available)
          .help(
            currentMode == .available
              ? "Choose how to search available ports"
              : "Search scopes are available when searching available ports"
          )
        }
      }
      }
    }
  }

  private var mainPane: some View {
    VStack(spacing: 0) {
      paneHeader
      list
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var paneHeader: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(
        currentMode == .configuration
          ? "Configuration" : currentMode == .health ? "Health" : "\(currentMode.rawValue) Ports"
      )
      .font(.title2.weight(.semibold))
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }

  @ViewBuilder
  private var detailPane: some View {
    Group {
      if currentMode == .available, let name = searchSelection {
        PortDetailView(
          name: name,
          isInstalled: model.ports.contains { $0.name == name },
          onInstalled: { await model.load() },
          onUninstalled: { await model.load() },
          onOpenPort: openPort)
      } else if currentMode == .outdated,
        let port = outdatedModel.ports.first(where: { $0.id == outdatedSelection })
      {
        PortDetailView(
          name: port.name,
          subtitle: "\(port.installedVersion) → \(port.availableVersion)",
          onUpgrade: { await refreshAll() },
          onUninstalled: { await refreshAll() },
          onOpenPort: openPort)
      } else if currentMode == .inactive,
        let port = model.ports.first(where: { $0.id == inactiveSelection })
      {
        ContentUnavailableView {
          Label(port.name, systemImage: "archivebox")
        } description: {
          Text(
            "Inactive version \(port.version)_\(port.revision)"
              + (port.variants.isEmpty ? "" : " " + port.variants.map { "+" + $0 }.joined())
              + ". Remove it to reclaim disk space.")
        }
      } else if currentMode == .installed, let port = selectedPort {
        PortDetailView(
          name: port.name,
          subtitle: "\(port.version)_\(port.revision)" + (port.isActive ? "" : " (inactive)"),
          onUninstalled: { await model.load() },
          onOpenPort: openPort)
      } else if currentMode == .selections,
        let group = selectionsModel.groups.first(where: { $0.id == groupSelection })
      {
        SelectionDetailView(group: group) { await selectionsModel.load() }
      } else if currentMode == .health {
        ContentUnavailableView(
          "Health", systemImage: "stethoscope",
          description: Text("Check your MacPorts environment and reclaim disk space."))
      } else if currentMode == .configuration {
        ContentUnavailableView(
          "Configuration", systemImage: "gearshape",
          description: Text("Settings apply to the next command you run."))
      } else {
        ContentUnavailableView {
          Text("Select a port").font(.title2)
        } description: {
          Text(
            currentMode == .installed
              ? "Choose an installed port to see its details."
              : "Search for a port, then choose one to see its details.")
        } actions: {
          AppIconImage(size: 96)
        }
      }
    }
  }

  @ViewBuilder
  private var activityPane: some View {
    VStack(spacing: 0) {
      Divider()
        .overlay(
          Color.clear.frame(height: 8).contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
            .gesture(
              DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                  dragPreview = min(600, max(80, activityHeight - v.translation.height))
                }
                .onEnded { _ in
                  if let h = dragPreview { activityHeight = h }
                  dragPreview = nil
                })
        )
        .overlay(alignment: .top) {
          if let h = dragPreview {
            Rectangle().fill(Color.accentColor).frame(height: 2)
              .overlay(alignment: .trailing) {
                Text("\(Int(h)) pt").font(.caption2).padding(2)
                  .background(.regularMaterial)
                  .offset(y: -14)
              }
              .offset(y: activityHeight - h)
          }
        }
      ActivityLogView(height: activityHeight)
    }
  }

  private var subtitle: String {
    switch currentMode {
    case .installed: "\(filtered.count) of \(model.ports.count)"
    case .available: "\(searchModel.results.count) results"
    case .outdated: "\(outdatedModel.ports.count) outdated"
    case .inactive: "\(inactivePorts.count) inactive"
    case .selections: "\(selectionsModel.groups.count) groups"
    case .health: "Environment checks"
    case .configuration: "Settings"
    }
  }

  private var searchPrompt: String {
    guard searchIsEnabled else { return "" }
    return currentMode == .available
      ? "Search available ports" : "Filter \(currentMode.rawValue.lowercased()) ports"
  }

  private var searchIsEnabled: Bool {
    switch currentMode {
    case .installed, .available, .outdated, .inactive: true
    case .selections, .health, .configuration: false
    }
  }

  @ViewBuilder private var list: some View {
    if currentMode == .configuration {
      ConfigurationView(
        search: $search,
        scope: $scope,
        onSearch: {
          guard currentMode == .available else { return }
          searchModel.search(search, scope: scope)
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if currentMode == .health {
      HealthView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      searchableList
    }
  }

  private var searchableList: some View {
    Group {
      switch currentMode {
      case .installed: installedList
      case .available: searchList
      case .outdated: outdatedList
      case .inactive: inactiveList
      case .selections: selectionsList
      case .health, .configuration: EmptyView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: scope) {
      if currentMode == .available, searchModel.hasSearched, !search.isEmpty {
        searchModel.search(search, scope: scope)
      }
    }
    .onSubmit(of: .search) {
      guard currentMode == .available else { return }
      searchModel.search(search, scope: scope)
    }
  }

  @ViewBuilder private var searchList: some View {
    if let error = searchModel.errorMessage {
      ContentUnavailableView(
        "Search failed", systemImage: "exclamationmark.triangle",
        description: Text(error))
    } else if searchModel.isSearching {
      ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if !searchModel.hasSearched {
      ContentUnavailableView(
        "Search MacPorts", systemImage: "magnifyingglass",
        description: Text("Type a name or keyword and press Return."))
    } else if searchModel.results.isEmpty {
      ContentUnavailableView.search(text: search)
    } else {
      let installed = Set(model.ports.map(\.name))
      let names =
        prebuiltOnly
        ? searchModel.results.filter { searchModel.binary[$0] == .available }
        : searchModel.results
      let rows = names.map { SearchRow(name: $0, isInstalled: installed.contains($0)) }
      Table(rows, selection: $searchSelection) {
        TableColumn("Name", value: \.name)
        TableColumn("Pre-built") { row in
          binaryHint(row.name)
        }
        .width(min: 70, ideal: 80, max: 100)
        TableColumn("Status") { row in
          searchStatus(row)
        }
      }
    }
  }

  @ViewBuilder private func binaryHint(_ name: String) -> some View {
    binaryHint(searchModel.binary[name], pending: searchModel.binaryCheckPending(name))
  }

  @ViewBuilder private func binaryHint(_ value: BinaryAvailability?, pending: Bool) -> some View {
    switch value {
    case .available:
      Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        .help("A pre-built binary exists for this Mac")
    case .unavailable:
      Text("–").foregroundStyle(.secondary).help("No pre-built binary found; builds from source")
    case .unknown:
      Text("?").foregroundStyle(.secondary).help("Couldn't reach the archive server")
    case nil:
      if pending {
        ProgressView().controlSize(.mini)
      } else {
        Text("")
      }
    }
  }

  @ViewBuilder private func searchStatus(_ row: SearchRow) -> some View {
    switch activity.progress[row.name] {
    case .working(let phase):
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(phase + "…")
      }
      .foregroundStyle(.tint)
    case .queued:
      Label("Waiting…", systemImage: "clock").foregroundStyle(.secondary)
    case .done:
      Label("Installed", systemImage: "shippingbox.fill").foregroundStyle(.secondary)
    case nil:
      Label(
        row.isInstalled ? "Installed" : "Not installed",
        systemImage: row.isInstalled ? "shippingbox.fill" : "shippingbox"
      )
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var inactiveList: some View {
    if inactivePorts.isEmpty {
      ContentUnavailableView(
        "No inactive ports", systemImage: "archivebox",
        description: Text("Old versions left behind by upgrades appear here."))
    } else {
      Table(inactivePorts, selection: $inactiveSelection, sortOrder: $sortOrder) {
        TableColumn("Name", value: \.name)
        TableColumn("Version") { Text("\($0.version)_\($0.revision)") }
        TableColumn("Variants") {
          Text($0.variants.map { "+" + $0 }.joined(separator: " ")).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private var selectionsList: some View {
    if let error = selectionsModel.errorMessage {
      ContentUnavailableView(
        "Can't read selections", systemImage: "exclamationmark.triangle",
        description: Text(error))
    } else if selectionsModel.isLoading && selectionsModel.groups.isEmpty {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if selectionsModel.groups.isEmpty {
      ContentUnavailableView(
        "No selection groups", systemImage: "arrow.left.arrow.right.circle",
        description: Text("Install ports such as clang or python to choose between versions."))
    } else {
      Table(selectionsModel.groups, selection: $groupSelection) {
        TableColumn("Group", value: \.name)
        TableColumn("Selected") {
          Text($0.selected).foregroundStyle($0.isSet ? .primary : .secondary)
        }
      }
    }
  }

  @ViewBuilder private var outdatedList: some View {
    if let error = outdatedModel.errorMessage {
      ContentUnavailableView(
        "Can't check for updates", systemImage: "exclamationmark.triangle",
        description: Text(error))
    } else if outdatedModel.isLoading && outdatedModel.ports.isEmpty {
      ProgressView("Checking…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if outdatedModel.ports.isEmpty {
      ContentUnavailableView(
        "Everything is up to date", systemImage: "checkmark.circle",
        description: Text("No installed ports have newer versions."))
    } else {
      let rows = outdatedModel.ports.filter {
        (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
          && (!prebuiltOnly || outdatedModel.binary[$0.name] == .available)
      }
      Table(rows, selection: $outdatedSelection) {
        TableColumn("Name", value: \.name)
        TableColumn("Installed", value: \.installedVersion)
        TableColumn("Available", value: \.availableVersion)
        TableColumn("Pre-built") { row in
          binaryHint(
            outdatedModel.binary[row.name],
            pending: outdatedModel.binary.isEmpty
              || outdatedModel.binary[row.name] == nil)
        }
        .width(min: 70, ideal: 80, max: 100)
      }
    }
  }

  @ViewBuilder private var installedList: some View {
    if let error = model.errorMessage {
      ContentUnavailableView(
        "Can't read ports", systemImage: "exclamationmark.triangle",
        description: Text(error))
    } else if model.isLoading && model.ports.isEmpty {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      Table(filtered, selection: $selection, sortOrder: $sortOrder) {
        TableColumn("Name", value: \.name)
        TableColumn("Version", value: \.version)
        TableColumn("Variants") { Text($0.variants.map { "+" + $0 }.joined(separator: " ")) }
        TableColumn("Status") {
          Text($0.isActive ? "Active" : "Inactive")
            .foregroundStyle($0.isActive ? .primary : .secondary)
        }
      }
    }
  }
}
