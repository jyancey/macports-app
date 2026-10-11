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
  /// True when the last load failed because there is no `port` at the
  /// configured path.
  private(set) var isPortMissing = false

  typealias Fetch = @Sendable () async throws -> [InstalledPort]
  private let fetch: Fetch

  /// The default uses a new client each time, so a changed `port` path
  /// applies at once.
  init(fetch: @escaping Fetch = { try await PortClient().installedPorts() }) {
    self.fetch = fetch
  }

  func load() async {
    isLoading = true
    errorMessage = nil
    isPortMissing = false
    defer { isLoading = false }
    do {
      ports = try await fetch()
    } catch {
      ports = []
      errorMessage = error.localizedDescription
      if case PortClientError.notInstalled = error { isPortMissing = true }
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

  /// The last search asked for, so a failed one can be tried again.
  private var lastRequest: (term: String, scope: SearchScope)?

  /// Runs the last search again.
  func retry() {
    guard let lastRequest else { return }
    search(lastRequest.term, scope: lastRequest.scope)
  }

  /// Starts a search, cancelling (and terminating) any search still running so
  /// an older, slower one can't replace the newer results.
  func search(_ term: String, scope: SearchScope) {
    lastRequest = (term, scope)
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

  /// Choices made but not yet shown by a reload, by group name, so a picker
  /// doesn't snap back while the command runs.
  private(set) var pending: [String: String] = [:]

  typealias Fetch = @Sendable () async throws -> [PortSelectGroup]
  typealias SetSelection =
    @Sendable (
      _ group: String, _ option: String, _ onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> Void
  private let fetch: Fetch
  private let setSelection: SetSelection
  @ObservationIgnored private var freshness = Freshness()

  init(
    fetch: @escaping Fetch = { try await PortClient().selections() },
    setSelection: @escaping SetSelection = { group, option, out in
      try await PortClient().setSelection(group: group, option: option, onOutput: out)
    }
  ) {
    self.fetch = fetch
    self.setSelection = setSelection
  }

  /// The option to show for `group`: a pending choice, else the current one.
  func shownSelection(_ group: PortSelectGroup) -> String {
    pending[group.name] ?? group.selected
  }

  /// Selects `option` ("none" unsets) through the Activity log, then reloads.
  func select(_ option: String, in group: PortSelectGroup, activity: ActivityLog) async {
    guard !activity.isRunning, option != shownSelection(group) else { return }
    pending[group.name] = option
    defer { pending[group.name] = nil }
    let setSelection = self.setSelection
    await activity.run("sudo port select --set \(group.name) \(option)", name: group.name) { out in
      try await setSelection(group.name, option, out)
    }
    await load()
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
  var ports: [OutdatedPort] = [] {
    didSet { byName = Dictionary(ports.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }) }
  }
  private var byName: [String: OutdatedPort] = [:]
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

  /// The newer version of an installed port, if it has one. Only the active
  /// version is upgraded, so inactive copies never have an update.
  func update(for port: InstalledPort) -> OutdatedPort? {
    port.isActive ? byName[port.name] : nil
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
  private let activity: ActivityLog
  @State private var model: InstalledPortsModel
  @State private var searchModel = SearchModel()
  @State private var outdatedModel: OutdatedModel
  @State private var outdatedSelection: Set<OutdatedPort.ID> = []
  @State private var inactiveSelection: Set<InstalledPort.ID> = []
  @State private var selectionsModel = SelectionsModel()
  @State private var healthModel = HealthModel()
  @State private var configurationModel = ConfigurationModel()
  @State private var detailCache: PortDetailCache
  @State private var actions: PortActions
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

  init(activity: ActivityLog) {
    self.activity = activity
    // Created together so that the actions reload these same models.
    let installed = InstalledPortsModel()
    let outdated = OutdatedModel()
    let cache = PortDetailCache()
    _model = State(initialValue: installed)
    _outdatedModel = State(initialValue: outdated)
    _detailCache = State(initialValue: cache)
    _actions = State(
      initialValue: PortActions(activity: activity) {
        await Self.reloadPorts(installed: installed, outdated: outdated, cache: cache)
      })
  }

  private var currentMode: BrowseMode { mode ?? .installed }
  private var isSinglePaneMode: Bool {
    currentMode == .health || currentMode == .configuration
  }

  var body: some View {
    split
      .environment(detailCache)
      .environment(actions)
      .sheet(item: $actions.installRequest) { request in
        InstallOptionsView(name: request.name) { flags in
          Task { await actions.install(request.name, flags: flags) }
        }
      }
      .confirmationDialog(
        "Uninstall \(actions.uninstallRequest ?? "")?",
        isPresented: Binding(
          get: { actions.uninstallRequest != nil },
          set: { if !$0 { actions.uninstallRequest = nil } }),
        presenting: actions.uninstallRequest
      ) { name in
        Button("Uninstall", role: .destructive) { Task { await actions.confirmUninstall(name) } }
      } message: { _ in
        Text(
          "This removes the port from your system. macOS administrator authorization will be requested."
        )
      }
      .confirmationDialog(
        activateTitle,
        isPresented: Binding(
          get: { actions.activateRequest != nil },
          set: { if !$0 { actions.activateRequest = nil } }),
        presenting: actions.activateRequest
      ) { port in
        Button("Activate") { Task { await actions.confirmActivate(port) } }
      } message: { port in
        Text(activateMessage(port))
      }
      .confirmationDialog(
        removeAllInactiveTitle, isPresented: $actions.removeAllInactiveRequested
      ) {
        Button("Remove All", role: .destructive) {
          Task {
            await actions.confirmRemoveAllInactive()
            inactiveSelection = []
          }
        }
      } message: {
        Text(
          "Old versions left behind by upgrades will be uninstalled to reclaim disk space. "
            + "Active versions are not affected. "
            + "macOS administrator authorization will be requested.")
      }
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

  private var removeAllInactiveTitle: String {
    let count = model.ports.filter { !$0.isActive }.count
    return count == 1 ? "Remove 1 inactive version?" : "Remove all \(count) inactive versions?"
  }

  private var activateTitle: String {
    guard let port = actions.activateRequest else { return "" }
    return "Activate \(port.name) \(port.version)_\(port.revision)?"
  }

  private func activateMessage(_ port: InstalledPort) -> String {
    let replaced =
      activeVersion(of: port.name).map {
        "\(port.name) \($0.version)_\($0.revision) will be deactivated. It stays installed. "
      } ?? ""
    return replaced + "macOS administrator authorization will be requested."
  }

  /// Reloads the installed and outdated lists and forgets cached port details.
  private static func reloadPorts(
    installed: InstalledPortsModel, outdated: OutdatedModel, cache: PortDetailCache
  ) async {
    cache.removeAll()
    async let installedLoad: Void = installed.load()
    async let outdatedLoad: Void = outdated.load()
    _ = await (installedLoad, outdatedLoad)
  }

  private func refreshAll() async {
    async let ports: Void = Self.reloadPorts(
      installed: model, outdated: outdatedModel, cache: detailCache)
    if currentMode == .selections { await selectionsModel.load() }
    if currentMode == .configuration { await configurationModel.load() }
    await ports
  }

  /// Selected rows of the Outdated table, in table order.
  private var selectedOutdated: [OutdatedPort] {
    outdatedModel.ports.filter { outdatedSelection.contains($0.id) }
  }

  /// Selected rows of the Inactive table, in table order.
  private var selectedInactive: [InstalledPort] {
    model.ports.filter { !$0.isActive && inactiveSelection.contains($0.id) }
  }

  private var upgradeSelectedButton: some View {
    Button("Upgrade Selected", systemImage: "arrow.up.circle") {
      let names = selectedOutdated.map(\.name)
      Task { await actions.upgrade(names) }
    }
    .disabled(activity.isRunning || selectedOutdated.isEmpty)
    .help("Upgrade the selected ports")
  }

  private var upgradeAllButton: some View {
    Button("Upgrade All", systemImage: "desktopcomputer.and.arrow.down") {
      Task { await actions.upgradeAll() }
    }
    .disabled(activity.isRunning || outdatedModel.ports.isEmpty)
    .help("Upgrade every outdated port")
  }

  private var removeInactiveButtons: some View {
    Group {
      Button("Remove Selected", systemImage: "eraser.badge.xmark") {
        let ports = selectedInactive
        Task {
          await actions.remove(ports)
          inactiveSelection = []
        }
      }
      .disabled(activity.isRunning || selectedInactive.isEmpty)
      .help("Remove the selected inactive versions")
      Button("Remove All", systemImage: "eraser.badge.xmark.fill") {
        actions.requestRemoveAllInactive()
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
              .badge(badgeCount(item))
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
            // An AppKit split view, so the divider between the list and the
            // detail can be dragged.
            HSplitView {
              mainPane
                .frame(minWidth: 380, idealWidth: 460, maxHeight: .infinity)
              detailPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
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
          systemImage: "sidebar.left"
        ) {
          isSidebarVisible.toggle()
        }
        .help(isSidebarVisible ? "Hide the navigation sidebar" : "Show the navigation sidebar")
      }
      ToolbarItem {
        Button {
          activity.isVisible.toggle()
        } label: {
          Label {
            Text("Activity Log")
          } icon: {
            ActivityToolbarIcon(log: activity)
          }
        }
        .help(ActivityToolbarIcon.help(activity))
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
        ToolbarItem { upgradeSelectedButton }
        ToolbarItem { upgradeAllButton }
      }
      if currentMode == .inactive { ToolbarItemGroup { removeInactiveButtons } }
      ToolbarItem {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshAll() } }
          .disabled(model.isLoading || outdatedModel.isLoading)
          .help("Reload the port lists (⌘R)")
      }
    }
  }

  @ViewBuilder private var mainPane: some View {
    Group {
      switch currentMode {
      case .installed:
        InstalledListView(
          model: model, outdated: outdatedModel, actions: actions, filter: search,
          sortOrder: $sortOrder, selection: $selection, showConfiguration: { mode = .configuration }
        )
        .searchable(text: $search, placement: .toolbar, prompt: Text(searchPrompt))
        .searchFocused($searchFocused)
      case .available:
        SearchResultsView(
          searchModel: searchModel, installed: model, activity: activity, actions: actions,
          prebuiltOnly: prebuiltOnly, scope: $scope,
          selection: $searchSelection
        )
        .searchable(text: $search, placement: .toolbar, prompt: Text(searchPrompt))
        .searchFocused($searchFocused)
      case .outdated:
        OutdatedListView(
          model: outdatedModel, actions: actions, filter: search, prebuiltOnly: prebuiltOnly,
          selection: $outdatedSelection
        )
        .searchable(text: $search, placement: .toolbar, prompt: Text(searchPrompt))
        .searchFocused($searchFocused)
      case .inactive:
        InactiveListView(
          model: model, actions: actions, filter: search, sortOrder: $sortOrder,
          selection: $inactiveSelection
        )
        .searchable(text: $search, placement: .toolbar, prompt: Text(searchPrompt))
        .searchFocused($searchFocused)
      case .selections:
        SelectionsListView(model: selectionsModel, activity: activity, selection: $groupSelection)
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
        PortDetailView(name: name, isInstalled: model.names.contains(name), onOpenPort: openPort)
      } else if currentMode == .outdated, !selectedOutdated.isEmpty {
        let ports = selectedOutdated
        if ports.count == 1, let port = ports.first {
          PortDetailView(
            name: port.name,
            subtitle: "\(port.installedVersion) → \(port.availableVersion)",
            canUpgrade: true,
            onOpenPort: openPort)
        } else {
          BatchSelectionView(
            title: "\(ports.count) Ports Selected", systemImage: "arrow.triangle.2.circlepath",
            items: ports.map { "\($0.name) \($0.installedVersion) → \($0.availableVersion)" },
            actionTitle: "Upgrade \(ports.count) Ports",
            actionImage: "desktopcomputer.and.arrow.down", isDisabled: activity.isRunning
          ) {
            Task { await actions.upgrade(ports.map(\.name)) }
          }
        }
      } else if currentMode == .inactive, !selectedInactive.isEmpty {
        let ports = selectedInactive
        if ports.count == 1, let port = ports.first {
          PortDetailView(
            name: port.name, subtitle: inactiveSubtitle(port), inactiveVersion: port,
            onOpenPort: openPort)
        } else {
          BatchSelectionView(
            title: "\(ports.count) Inactive Versions Selected", systemImage: "archivebox",
            items: ports.map { "\($0.name) \($0.version)_\($0.revision)" },
            actionTitle: "Remove \(ports.count) Versions", actionImage: "trash",
            role: .destructive, isDisabled: activity.isRunning
          ) {
            Task {
              await actions.remove(ports)
              inactiveSelection = []
            }
          }
        }
      } else if currentMode == .installed, let port = selectedPort {
        if port.isActive {
          let update = outdatedModel.update(for: port)
          PortDetailView(
            name: port.name,
            subtitle: "\(port.version)_\(port.revision)"
              + (update.map { " → \($0.availableVersion)" } ?? ""),
            canUpgrade: update != nil,
            onOpenPort: openPort)
        } else {
          PortDetailView(
            name: port.name, subtitle: inactiveSubtitle(port), inactiveVersion: port,
            onOpenPort: openPort)
        }
      } else if currentMode == .selections,
        let group = selectionsModel.groups.first(where: { $0.id == groupSelection })
      {
        SelectionDetailView(group: group, model: selectionsModel)
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
          Text(emptyDetailMessage)
        } actions: {
          AppIconImage(size: 96)
        }
      }
    }
  }

  /// "1.2_0 +universal (inactive), active: 1.3_0"
  private func inactiveSubtitle(_ port: InstalledPort) -> String {
    var text = "\(port.version)_\(port.revision)"
    if !port.variants.isEmpty { text += " " + port.variants.map { "+" + $0 }.joined() }
    text += " (inactive)"
    if let active = activeVersion(of: port.name) {
      text += ", active: \(active.version)_\(active.revision)"
    }
    return text
  }

  private func activeVersion(of name: String) -> InstalledPort? {
    model.ports.first { $0.name == name && $0.isActive }
  }

  private var emptyDetailMessage: String {
    switch currentMode {
    case .installed: "Choose an installed port to see its details."
    case .outdated: "Choose an outdated port to see its update."
    case .inactive: "Choose an inactive version to activate or remove it."
    default: "Search for a port, then choose one to see its details."
    }
  }

  /// The number shown beside a sidebar item; zero shows no badge.
  private func badgeCount(_ item: BrowseMode) -> Int {
    switch item {
    case .outdated: outdatedModel.ports.count
    case .inactive: model.ports.count { !$0.isActive }
    case .health: healthModel.findings?.count ?? 0
    default: 0
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
