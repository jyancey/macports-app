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

    func search(_ term: String) async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let found = try await client.search(term)
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

enum BrowseMode: String, CaseIterable, Identifiable {
    case installed = "Installed", available = "Available"
    var id: Self { self }
}

struct InstalledPortsView: View {
    @State private var model = InstalledPortsModel()
    @State private var searchModel = SearchModel()
    @State private var mode = BrowseMode.installed
    @State private var searchSelection: String?
    @State private var search = ""
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

    var body: some View {
        NavigationSplitView {
            list
                .navigationSplitViewColumnWidth(min: 420, ideal: 520)
        } detail: {
            if mode == .available, let name = searchSelection {
                PortDetailView(name: name,
                               isInstalled: model.ports.contains { $0.name == name },
                               onInstalled: { await model.load() })
            } else if mode == .installed, let port = selectedPort {
                PortDetailView(name: port.name,
                               subtitle: "\(port.version)_\(port.revision)" + (port.isActive ? "" : " (inactive)"))
            } else {
                ContentUnavailableView {
                    Text("Select a port").font(.title2)
                } description: {
                    Text(mode == .installed ? "Choose an installed port to see its details."
                                            : "Search for a port, then choose one to see its details.")
                } actions: {
                    MacPortsLogo(size: 64)
                }
            }
        }
        .navigationTitle(mode == .installed ? "Installed Ports" : "Available Ports")
        .navigationSubtitle(mode == .installed
            ? "\(filtered.count) of \(model.ports.count)"
            : "\(searchModel.results.count) results")
        .toolbar {
            ToolbarItem(placement: .navigation) { MacPortsLogo(size: 22) }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isLoading)
            }
        }
        .task { await model.load() }
    }

    private var list: some View {
        Group {
            if mode == .installed { installedList } else { searchList }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(BrowseMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
        }
        .searchable(text: $search,
                    prompt: mode == .installed ? "Filter installed ports" : "Search available ports")
        .onSubmit(of: .search) {
            guard mode == .available else { return }
            Task { await searchModel.search(search) }
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
            List(searchModel.results, id: \.self, selection: $searchSelection) { name in
                HStack {
                    Text(name)
                    Spacer()
                    if installed.contains(name) {
                        Text("Installed").font(.caption).foregroundStyle(.secondary)
                    }
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
