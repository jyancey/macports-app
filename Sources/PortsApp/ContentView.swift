import SwiftUI
import PortsKit

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

    private let client = PortClient()

    func search(_ term: String, scope: SearchScope) async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let found = try await client.search(term, scope: scope)
            guard !Task.isCancelled else { return }
            results = found
            hasSearched = true
        } catch is CancellationError {
        } catch {
            results = []
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

    private let client = PortClient()

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
    case installed = "Installed", available = "Available", outdated = "Outdated", inactive = "Inactive"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .installed: "checkmark.circle"
        case .available: "magnifyingglass"
        case .outdated: "arrow.triangle.2.circlepath"
        case .inactive: "archivebox"
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
    @State private var mode: BrowseMode? = .installed
    @State private var searchSelection: String?
    @State private var search = ""
    @State private var scope = SearchScope.name
    @State private var sortOrder = [KeyPathComparator(\InstalledPort.name)]

    @State private var selection: InstalledPort.ID?

    private var filtered: [InstalledPort] {
        let matches = search.isEmpty ? model.ports
            : model.ports.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return matches.sorted(using: sortOrder)
    }

    private var selectedPort: InstalledPort? {
        model.ports.first { $0.id == selection }
    }

    private var inactivePorts: [InstalledPort] {
        let matches = model.ports.filter { !$0.isActive }
        let shown = search.isEmpty ? matches : matches.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return shown.sorted(using: sortOrder)
    }

    private var currentMode: BrowseMode { mode ?? .installed }

    var body: some View {
        VStack(spacing: 0) {
            split
            if activity.isVisible {
                Divider()
                ActivityLogView()
            }
        }
        .task { await model.load() }
        .task(id: mode) {
            if currentMode == .outdated { await outdatedModel.load() }
        }
    }

    private func refreshAll() async {
        await model.load()
        await outdatedModel.load()
    }

    private var upgradeAllButton: some View {
        Button("Upgrade All", systemImage: "arrow.up.circle") {
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
            Button("Remove Selected", systemImage: "trash") {
                guard let port = model.ports.first(where: { $0.id == inactiveSelection }) else { return }
                Task {
                    _ = await activity.run("sudo port uninstall \(port.name) @\(port.version)_\(port.revision)",
                                           name: port.name) { out in
                        try await PortClient().uninstall(port, onOutput: out)
                    }
                    inactiveSelection = nil
                    await model.load()
                }
            }
            .disabled(activity.isRunning || inactiveSelection == nil)
            .help("Remove the selected inactive version")
            Button("Remove All", systemImage: "eraser.fill") {
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

    private var split: some View {
        NavigationSplitView {
            List(BrowseMode.allCases, selection: $mode) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } content: {
            list
                .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        } detail: {
            if currentMode == .available, let name = searchSelection {
                PortDetailView(name: name,
                               isInstalled: model.ports.contains { $0.name == name },
                               onInstalled: { await model.load() },
                               onUninstalled: { await model.load() })
            } else if currentMode == .outdated, let port = outdatedModel.ports.first(where: { $0.id == outdatedSelection }) {
                PortDetailView(name: port.name,
                               subtitle: "\(port.installedVersion) → \(port.availableVersion)",
                               onUpgrade: { await refreshAll() },
                               onUninstalled: { await refreshAll() })
            } else if currentMode == .inactive, let port = model.ports.first(where: { $0.id == inactiveSelection }) {
                ContentUnavailableView {
                    Label(port.name, systemImage: "archivebox")
                } description: {
                    Text("Inactive version \(port.version)_\(port.revision)"
                         + (port.variants.isEmpty ? "" : " " + port.variants.map { "+" + $0 }.joined())
                         + ". Remove it to reclaim disk space.")
                }
            } else if currentMode == .installed, let port = selectedPort {
                PortDetailView(name: port.name,
                               subtitle: "\(port.version)_\(port.revision)" + (port.isActive ? "" : " (inactive)"),
                               onUninstalled: { await model.load() })
            } else {
                ContentUnavailableView {
                    Text("Select a port").font(.title2)
                } description: {
                    Text(currentMode == .installed ? "Choose an installed port to see its details."
                                            : "Search for a port, then choose one to see its details.")
                } actions: {
                    MacPortsLogo(size: 64)
                }
            }
        }
        .navigationTitle("\(currentMode.rawValue) Ports")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) { MacPortsLogo(size: 22) }
            ToolbarItem {
                Button("Activity Log", systemImage: "terminal") { activity.isVisible.toggle() }
                    .help("Show or hide the activity log")
            }
            if currentMode == .outdated { ToolbarItem { upgradeAllButton } }
            if currentMode == .inactive { ToolbarItemGroup { removeInactiveButtons } }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshAll() } }
                    .disabled(model.isLoading || outdatedModel.isLoading)
            }
        }
    }

    private var subtitle: String {
        switch currentMode {
        case .installed: "\(filtered.count) of \(model.ports.count)"
        case .available: "\(searchModel.results.count) results"
        case .outdated: "\(outdatedModel.ports.count) outdated"
        case .inactive: "\(inactivePorts.count) inactive"
        }
    }

    private var list: some View {
        Group {
            switch currentMode {
            case .installed: installedList
            case .available: searchList
            case .outdated: outdatedList
            case .inactive: inactiveList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $search,
                    prompt: currentMode == .available ? "Search available ports" : "Filter \(currentMode.rawValue.lowercased()) ports")
        .searchScopes($scope) {
            if currentMode == .available {
                ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
            }
        }
        .onChange(of: scope) {
            if currentMode == .available, searchModel.hasSearched, !search.isEmpty {
                Task { await searchModel.search(search, scope: scope) }
            }
        }
        .onSubmit(of: .search) {
            guard currentMode == .available else { return }
            Task { await searchModel.search(search, scope: scope) }
        }
    }

    @ViewBuilder private var searchList: some View {
        if let error = searchModel.errorMessage {
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if searchModel.isSearching {
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !searchModel.hasSearched {
            ContentUnavailableView("Search MacPorts", systemImage: "magnifyingglass",
                                   description: Text("Type a name or keyword and press Return."))
        } else if searchModel.results.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            let installed = Set(model.ports.map(\.name))
            let rows = searchModel.results.map { SearchRow(name: $0, isInstalled: installed.contains($0)) }
            Table(rows, selection: $searchSelection) {
                TableColumn("Name", value: \.name)
                TableColumn("Status") { row in
                    Text(row.isInstalled ? "Installed" : "")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var inactiveList: some View {
        if inactivePorts.isEmpty {
            ContentUnavailableView("No inactive ports", systemImage: "archivebox",
                                   description: Text("Old versions left behind by upgrades appear here."))
        } else {
            Table(inactivePorts, selection: $inactiveSelection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name)
                TableColumn("Version") { Text("\($0.version)_\($0.revision)") }
                TableColumn("Variants") { Text($0.variants.map { "+" + $0 }.joined(separator: " ")).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var outdatedList: some View {
        if let error = outdatedModel.errorMessage {
            ContentUnavailableView("Can't check for updates", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if outdatedModel.isLoading && outdatedModel.ports.isEmpty {
            ProgressView("Checking…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if outdatedModel.ports.isEmpty {
            ContentUnavailableView("Everything is up to date", systemImage: "checkmark.circle",
                                   description: Text("No installed ports have newer versions."))
        } else {
            let rows = outdatedModel.ports.filter {
                search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
            }
            Table(rows, selection: $outdatedSelection) {
                TableColumn("Name", value: \.name)
                TableColumn("Installed", value: \.installedVersion)
                TableColumn("Available", value: \.availableVersion)
            }
        }
    }

    @ViewBuilder private var installedList: some View {
        if let error = model.errorMessage {
            ContentUnavailableView("Can't read ports", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name)
                TableColumn("Version", value: \.version)
                TableColumn("Variants") { Text($0.variants.map { "+" + $0 }.joined(separator: " ")) }
                TableColumn("Status") { Text($0.isActive ? "Active" : "Inactive")
                    .foregroundStyle($0.isActive ? .primary : .secondary) }
            }
            .overlay { if model.isLoading && model.ports.isEmpty { ProgressView() } }
        }
    }
}
