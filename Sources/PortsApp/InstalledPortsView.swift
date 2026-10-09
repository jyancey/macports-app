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

    private var filtered: [InstalledPort] {
        let matches = search.isEmpty ? model.ports
            : model.ports.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return matches.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if let error = model.errorMessage {
                ContentUnavailableView("Can't read ports", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                Table(filtered, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Version", value: \.version)
                    TableColumn("Revision") { Text("\($0.revision)") }
                    TableColumn("Variants") { Text($0.variants.map { "+" + $0 }.joined(separator: " ")) }
                    TableColumn("Status") { Text($0.isActive ? "Active" : "Inactive")
                        .foregroundStyle($0.isActive ? .primary : .secondary) }
                }
            }
        }
        .searchable(text: $search, prompt: "Filter installed ports")
        .navigationTitle("Installed Ports")
        .navigationSubtitle("\(filtered.count) of \(model.ports.count)")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                .disabled(model.isLoading)
        }
        .overlay { if model.isLoading && model.ports.isEmpty { ProgressView() } }
        .task { await model.load() }
    }
}
