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

/// Sidebar destinations. Add a case here to add a tab.
enum BrowseMode: String, CaseIterable, Identifiable {
    case installed = "Installed", available = "Available"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .installed: "checkmark.circle"
        case .available: "magnifyingglass"
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
        .navigationTitle(currentMode == .installed ? "Installed Ports" : "Available Ports")
        .navigationSubtitle(currentMode == .installed
            ? "\(filtered.count) of \(model.ports.count)"
            : "\(searchModel.results.count) results")
        .toolbar {
            ToolbarItem(placement: .navigation) { MacPortsLogo(size: 22) }
            ToolbarItem {
                Button("Activity Log", systemImage: "terminal") { activity.isVisible.toggle() }
                    .help("Show or hide the activity log")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isLoading)
            }
        }
    }

    private var list: some View {
        Group {
            if currentMode == .installed { installedList } else { searchList }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $search,
                    prompt: currentMode == .installed ? "Filter installed ports" : "Search available ports")
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
