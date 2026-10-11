import PortsKit
import SwiftUI

@MainActor
@Observable
final class InstalledPortsModel {
  var ports: [InstalledPort] = [] {
    didSet { names = Set(ports.map(\.name)) }
  }
  /// Names of the installed ports, for quick "is it installed" checks.
  private(set) var names: Set<String> = []
  var isLoading = false
  var errorMessage: String?

  func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      // A new client each time, so a changed `port` path applies at once.
      ports = try await PortClient().installedPorts()
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
  /// The term the current results are for (the field may have changed since).
  private(set) var searchedTerm = ""
  /// Pre-built binary hints for the current results; a missing key means
  /// not checked yet.
  private(set) var binary: [String: BinaryAvailability] = [:]
  private var binaryTask: Task<Void, Never>?

  typealias Search = @Sendable (_ term: String, _ scope: SearchScope) async throws -> [String]
  typealias BinaryHint = @Sendable (_ name: String) async -> BinaryAvailability

  private let runSearch: Search
  private let binaryHint: BinaryHint
  private static let binaryCheckLimit = 100

  /// Defaults run `port search` (with the `port` path configured at the time)
  /// and query the archive site; tests substitute their own.
  init(
    search: @escaping Search = { term, scope in
      try await PortClient().search(term, scope: scope)
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
      await checkBinariesInBatches(Array(names.prefix(Self.binaryCheckLimit))) { name in
        (name, await binaryHint(name))
      } deliver: { batch in
        binary.merge(batch) { $1 }
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
      searchedTerm = term
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

  typealias Fetch = @Sendable () async throws -> [PortSelectGroup]
  private let fetch: Fetch
  @ObservationIgnored private var freshness = Freshness()

  init(fetch: @escaping Fetch = { try await PortClient().selections() }) {
    self.fetch = fetch
  }

  /// Loads unless the groups were loaded recently and nothing has changed since.
  func loadIfStale() async {
    if freshness.isStale { await load() }
  }

  /// Marks the groups out of date, such as after a command changed the system.
  func invalidate() { freshness.invalidate() }

  func load() async {
    let token = freshness.begin()
    let previousError = errorMessage
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      groups = try await fetch()
      freshness.markLoaded(token)
    } catch is CancellationError {
      // Leaving the tab cancels the load; keep what was there.
      errorMessage = previousError
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

  typealias Fetch = @Sendable () async throws -> [OutdatedPort]
  private let fetch: Fetch
  @ObservationIgnored private var freshness = Freshness()

  init(fetch: @escaping Fetch = { try await PortClient().outdated() }) {
    self.fetch = fetch
  }

  func checkBinaries(installed: [InstalledPort]) {
    binaryTask?.cancel()
    binary = [:]
    let variants = Dictionary(
      installed.filter(\.isActive).map { ($0.name, $0.variants) },
      uniquingKeysWith: { first, _ in first })
    let batch = ports
    binaryTask = Task {
      await checkBinariesInBatches(batch) { port in
        let parts = port.availableVersion.split(separator: "_", maxSplits: 1)
        let version = parts.first.map(String.init) ?? port.availableVersion
        let revision = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return (
          port.name,
          await BinaryArchive.availability(
            name: port.name, version: version, revision: revision,
            variants: variants[port.name] ?? [])
        )
      } deliver: { batch in
        binary.merge(batch) { $1 }
      }
    }
  }

  /// Loads unless the list was loaded recently and nothing has changed since.
  func loadIfStale() async {
    if freshness.isStale { await load() }
  }

  /// Marks the list out of date, such as after a command changed the system.
  func invalidate() { freshness.invalidate() }

  func load() async {
    let token = freshness.begin()
    let previousError = errorMessage
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      ports = try await fetch()
      freshness.markLoaded(token)
    } catch is CancellationError {
      // Leaving the tab cancels the load; keep what was there.
      errorMessage = previousError
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

struct ContentView: View {
  @Environment(ActivityLog.self) private var activity
  @State private var model = InstalledPortsModel()
  @State private var searchModel = SearchModel()
  @State private var outdatedModel = OutdatedModel()
  @State private var outdatedSelection: String?
  @State private var inactiveSelection: InstalledPort.ID?
  @State private var selectionsModel = SelectionsModel()
  @State private var healthModel = HealthModel()
  @State private var configurationModel = ConfigurationModel()
  @State private var detailCache = PortDetailCache()
  @State private var groupSelection: String?
  @State private var mode: BrowseMode? = .installed
  @State private var searchSelection: String?
  @State private var search = ""
  @State private var scope = SearchScope.name
  @State private var prebuiltOnly = false
  @State private var sortOrder = [KeyPathComparator(\InstalledPort.name)]

  @State private var selection: InstalledPort.ID?

  private var selectedPort: InstalledPort? {
    model.ports.first { $0.id == selection }
  }

  @State private var isSidebarVisible = true
  @FocusState private var searchFocused: Bool

  private var currentMode: BrowseMode { mode ?? .installed }
  private var isSinglePaneMode: Bool {
    currentMode == .health || currentMode == .configuration
  }

  var body: some View {
    split
    .environment(detailCache)
    .task {
      await model.load()
      // Load the outdated list up front so its tab opens at once and the
      // sidebar can show how many updates there are.
      await outdatedModel.loadIfStale()
    }
    .task(id: outdatedModel.ports.map(\.availableVersion) + [String(model.ports.count)]) {
      outdatedModel.checkBinaries(installed: model.ports)
    }
    .task(id: mode) {
      if !searchIsEnabled { search = "" }
      if currentMode == .outdated { await outdatedModel.loadIfStale() }
      if currentMode == .selections { await selectionsModel.loadIfStale() }
    }
    .onChange(of: activity.completedRuns) {
      // A command may have changed what these show; reload on the next visit.
      outdatedModel.invalidate()
      selectionsModel.invalidate()
      configurationModel.invalidate()
      detailCache.removeAll()
    }
    .focusedSceneValue(\.windowActions, windowActions)
  }

  /// What the menu bar commands do in this window.
  private var windowActions: WindowActions {
    WindowActions(
      mode: currentMode,
      showMode: { mode = $0 },
      isSidebarVisible: isSidebarVisible,
      toggleSidebar: { isSidebarVisible.toggle() },
      isActivityVisible: activity.isVisible,
      toggleActivity: { activity.isVisible.toggle() },
      canRefresh: !(model.isLoading || outdatedModel.isLoading),
      refresh: { Task { await refreshAll() } },
      canSearch: searchIsEnabled,
      focusSearch: { if searchIsEnabled { searchFocused = true } })
  }

  private func refreshAll() async {
    detailCache.removeAll()
    async let installed: Void = model.load()
    async let outdated: Void = outdatedModel.load()
    if currentMode == .selections { await selectionsModel.load() }
    if currentMode == .configuration { await configurationModel.load() }
    _ = await (installed, outdated)
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
            Label(item.rawValue, systemImage: item.symbol)
              .badge(item == .outdated ? outdatedModel.ports.count : 0)
              .tag(item)
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
          ActivityPane()
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
    }
  }

  @ViewBuilder private var mainPane: some View {
    Group {
      switch currentMode {
      case .installed:
        InstalledListView(
          model: model, filter: search, sortOrder: $sortOrder, selection: $selection
        )
        .searchable(text: $search, placement: .toolbar, prompt: Text(searchPrompt))
        .searchFocused($searchFocused)
      case .available:
        SearchResultsView(
          searchModel: searchModel, installed: model, activity: activity,
          prebuiltOnly: prebuiltOnly, scope: $scope,
          selection: $searchSelection
        )
        .searchable(text: $search, placement: .toolbar, prompt: Text(searchPrompt))
        .searchFocused($searchFocused)
      case .outdated:
        OutdatedListView(
          model: outdatedModel, filter: search, prebuiltOnly: prebuiltOnly,
          selection: $outdatedSelection
        )
        .searchable(text: $search, placement: .toolbar, prompt: Text(searchPrompt))
        .searchFocused($searchFocused)
      case .inactive:
        InactiveListView(
          model: model, filter: search, sortOrder: $sortOrder, selection: $inactiveSelection
        )
        .searchable(text: $search, placement: .toolbar, prompt: Text(searchPrompt))
        .searchFocused($searchFocused)
      case .selections:
        SelectionsListView(model: selectionsModel, selection: $groupSelection)
      case .health:
        VStack(spacing: 0) {
          PaneHeader(title: "Health", subtitle: "Environment checks")
          HealthView(model: healthModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      case .configuration:
        VStack(spacing: 0) {
          PaneHeader(title: "Configuration", subtitle: "Settings")
          ConfigurationView(model: configurationModel, installedCount: model.ports.count)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

  @ViewBuilder
  private var detailPane: some View {
    Group {
      if currentMode == .available, let name = searchSelection {
        PortDetailView(
          name: name,
          isInstalled: model.names.contains(name),
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
}
