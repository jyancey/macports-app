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

    private let client = PortClient()

    func load(_ name: String) async {
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
    /// When set, an Upgrade button is offered and this runs after a successful upgrade.
    var onUpgrade: (() async -> Void)?
    /// Called after a successful uninstall.
    var onUninstalled: () async -> Void = {}
    @State private var confirmUninstall = false
    @Environment(ActivityLog.self) private var activity
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
            if isInstalled, let onUpgrade { upgradeControls(onUpgrade) }
            if isInstalled { uninstallControls } else { installControls }
        }
        .confirmationDialog("Uninstall \(name)?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) {
                Task {
                    let client = PortClient()
                    let ok = await activity.run("sudo port uninstall \(name)", name: name) { out in
                        try await client.uninstall(name, onOutput: out)
                    }
                    if ok { await onUninstalled() }
                }
            }
        } message: {
            Text("This removes the port from your system. You'll be asked for your administrator password.")
        }
    }

    @ViewBuilder private func upgradeControls(_ done: @escaping () async -> Void) -> some View {
        if activity.runningName != name {
            Button("Upgrade", systemImage: "arrow.up.circle") {
                Task {
                    let client = PortClient()
                    let ok = await activity.run("sudo port upgrade \(name)", name: name) { out in
                        try await client.upgrade(name, onOutput: out)
                    }
                    if ok { await done() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(activity.isRunning)
        }
    }

    @ViewBuilder private var uninstallControls: some View {
        if activity.runningName == name {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Working…").foregroundStyle(.secondary)
            }
        } else {
            Button("Uninstall", systemImage: "trash", role: .destructive) { confirmUninstall = true }
                .disabled(activity.isRunning)
        }
    }

    @ViewBuilder private var installControls: some View {
        if activity.runningName == name {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            }
        } else {
            Button("Install", systemImage: "arrow.down.circle") {
                Task {
                    let client = PortClient()
                    let ok = await activity.run("sudo port install \(name)", name: name) { out in
                        try await client.install(name, onOutput: out)
                    }
                    if ok {
                        await onInstalled()
                        await model.load(name)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(activity.isRunning)
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
