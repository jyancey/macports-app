import SwiftUI
import PortsKit

@MainActor
@Observable
final class PortDetailModel {
    enum Loadable<T: Sendable>: Sendable {
        case loading
        case loaded(T)
        case failed(String)
    }

    var info: Loadable<PortInfo> = .loading
    var files: Loadable<[String]> = .loading
    var dependents: Loadable<[String]> = .loading

    enum InstallState: Equatable { case idle, installing, failed(String) }
    var installState = InstallState.idle

    private let client = PortClient()

    /// Returns true when the install succeeded.
    func install(_ name: String) async -> Bool {
        installState = .installing
        do {
            try await client.install(name)
            installState = .idle
            return true
        } catch PortClientError.cancelled {
            installState = .idle
        } catch {
            installState = .failed(error.localizedDescription)
        }
        return false
    }

    func load(_ name: String) async {
        if installState != .installing { installState = .idle }
        info = .loading
        files = .loading
        dependents = .loading
        async let i = capture { try await self.client.info(for: name) }
        async let f = capture { try await self.client.contents(of: name) }
        async let d = capture { try await self.client.dependents(of: name) }
        let (infoResult, filesResult, dependentsResult) = await (i, f, d)
        guard !Task.isCancelled else { return }
        info = infoResult
        files = filesResult
        dependents = dependentsResult
    }

    private func capture<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Loadable<T> {
        do { return .loaded(try await work()) } catch { return .failed(error.localizedDescription) }
    }
}

struct PortDetailView: View {
    let name: String
    /// Shown under the name; defaults to the version from `port info`.
    var subtitle: String?
    /// When false, an Install button is offered.
    var isInstalled = true
    /// Called after a successful install so the caller can refresh its lists.
    var onInstalled: () async -> Void = {}
    @State private var model = PortDetailModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                infoSection
                dependentsSection
                filesSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: name) { await model.load(name) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.title.bold()).textSelection(.enabled)
                if let subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                } else if case .loaded(let info) = model.info {
                    Text(info.version).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isInstalled { installControls }
        }
    }

    @ViewBuilder private var installControls: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if model.installState == .installing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Installing…").foregroundStyle(.secondary)
                }
            } else {
                Button("Install", systemImage: "arrow.down.circle") {
                    Task {
                        if await model.install(name) {
                            await onInstalled()
                            await model.load(name)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            if case .failed(let message) = model.installState {
                Text(message).font(.caption).foregroundStyle(.red)
                    .lineLimit(4).frame(maxWidth: 320, alignment: .trailing)
            }
        }
    }

    @ViewBuilder private var infoSection: some View {
        switch model.info {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        case .loaded(let info):
            VStack(alignment: .leading, spacing: 12) {
                if !info.description.isEmpty {
                    Text(info.description).textSelection(.enabled)
                }
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                    row("Categories", info.categories.joined(separator: ", "))
                    if let homepage = info.homepage {
                        GridRow {
                            label("Homepage")
                            Link(homepage.absoluteString, destination: homepage)
                        }
                    }
                    row("License", info.license)
                    row("Maintainers", info.maintainers)
                    row("Variants", info.variants.map { "+" + $0 }.joined(separator: " "))
                    row("Platforms", info.platforms.joined(separator: ", "))
                    row("Sub-ports", info.subports.joined(separator: ", "))
                    row("Library deps", info.libDependencies.joined(separator: ", "))
                    row("Build deps", info.buildDependencies.joined(separator: ", "))
                    row("Runtime deps", info.runDependencies.joined(separator: ", "))
                }
            }
        }
    }

    @ViewBuilder private var dependentsSection: some View {
        if case .loaded(let names) = model.dependents, !names.isEmpty {
            DisclosureGroup("Required by (\(names.count))") {
                Text(names.joined(separator: ", ")).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var filesSection: some View {
        switch model.files {
        case .loaded(let files) where !files.isEmpty:
            DisclosureGroup("Installed files (\(files.count))") {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(files, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            EmptyView()
        }
    }

    private func label(_ title: String) -> some View {
        Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    @ViewBuilder private func row(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            GridRow {
                label(title)
                Text(value).textSelection(.enabled)
            }
        }
    }
}
