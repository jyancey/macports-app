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

struct InstalledPortsView: View {
    @State private var model = InstalledPortsModel()
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
            if let port = selectedPort {
                PortDetailView(port: port)
            } else {
                ContentUnavailableView {
                    Text("Select a port").font(.title2)
                } description: {
                    Text("Choose an installed port to see its details.")
                } actions: {
                    MacPortsLogo(size: 64)
                }
            }
        }
        .navigationTitle("Installed Ports")
        .navigationSubtitle("\(filtered.count) of \(model.ports.count)")
        .toolbar {
            ToolbarItem(placement: .navigation) { MacPortsLogo(size: 22) }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isLoading)
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder private var list: some View {
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
            .searchable(text: $search, prompt: "Filter installed ports")
            .overlay { if model.isLoading && model.ports.isEmpty { ProgressView() } }
        }
    }
}
