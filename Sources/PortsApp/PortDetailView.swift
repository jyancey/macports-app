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
    /// Whether a pre-built archive exists for the default variants; nil until checked.
    var binary: BinaryAvailability?

    private let client = PortClient()

    func load(_ name: String) async {
        info = .loading
        files = .loading
        dependents = .loading
        binary = nil
        async let i = capture { try await self.client.info(for: name) }
        async let f = capture { try await self.client.contents(of: name) }
        async let d = capture { try await self.client.dependents(of: name) }
        let (infoResult, filesResult, dependentsResult) = await (i, f, d)
        guard !Task.isCancelled else { return }
        info = infoResult
        files = filesResult
        dependents = dependentsResult
        if case .loaded(let info) = infoResult {
            let defaults = ((try? await client.variants(of: name)) ?? []).filter(\.isDefault).map(\.name)
            let result = await BinaryArchive.availability(
                name: name, version: info.version, revision: info.revision, variants: defaults)
            guard !Task.isCancelled else { return }
            binary = result
        }
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
    @State private var checkingVariants = false
    @State private var showInstallOptions = false
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
        .sheet(isPresented: $showInstallOptions) {
            InstallOptionsView(name: name) { install(flags: $0) }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isInstalled ? "shippingbox.fill" : "shippingbox")
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
                binaryBadge
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

    @ViewBuilder private var binaryBadge: some View {
        switch model.binary {
        case .available:
            Label("Pre-built binary available", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
                .help("MacPorts can download a pre-built archive for this Mac instead of compiling.")
        case .unavailable:
            Label("Builds from source", systemImage: "hammer")
                .font(.caption).foregroundStyle(.secondary)
                .help("No pre-built archive was found for this Mac; installing compiles the port.")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func upgradeControls(_ done: @escaping () async -> Void) -> some View {
        if activity.runningName != name {
            Button("Upgrade", systemImage: "desktopcomputer.and.arrow.down") {
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
            Button("Install", systemImage: "arrow.down.circle") { startInstall() }
            .buttonStyle(.borderedProminent)
            .disabled(activity.isRunning || checkingVariants)
        }
    }

    /// Installs straight away when the port has no variants; otherwise asks which to use.
    private func startInstall() {
        checkingVariants = true
        Task {
            let found = try? await PortClient().variants(of: name)
            checkingVariants = false
            if let found, found.isEmpty { install(flags: []) } else { showInstallOptions = true }
        }
    }

    private func install(flags: [String]) {
        Task {
            let client = PortClient()
            let title = (["sudo port install", name] + flags).joined(separator: " ")
            let ok = await activity.run(title, name: name) { out in
                try await client.install(name, variantFlags: flags, onOutput: out)
            }
            if ok {
                await onInstalled()
                await model.load(name)
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

/// Lets the user choose variants before installing.
struct InstallOptionsView: View {
    let name: String
    let onInstall: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var variants: [PortVariant]?
    @State private var errorMessage: String?
    @State private var selected: Set<String> = []
    @State private var info: PortInfo?
    @State private var binary: BinaryAvailability?

    /// Variant names that the current selection builds with, in the form archives are named.
    private var activeVariants: [String] {
        (variants ?? []).map(\.name).filter { selected.contains($0) }
    }

    private var customized: Bool {
        !PortVariantParser.flags(selected: selected, from: variants ?? []).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install \(name)").font(.title2.bold())
            content
            buildNotice
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") {
                    onInstall(PortVariantParser.flags(selected: selected, from: variants ?? []))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(variants == nil && errorMessage == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            do {
                let found = try await PortClient().variants(of: name)
                variants = found
                selected = Set(found.filter(\.isDefault).map(\.name))
            } catch {
                errorMessage = error.localizedDescription
            }
            info = try? await PortClient().info(for: name)
        }
        .task(id: activeVariants.joined(separator: "+") + (info?.version ?? "")) {
            guard let info, variants != nil else { return }
            binary = nil
            let result = await BinaryArchive.availability(
                name: name, version: info.version, revision: info.revision, variants: activeVariants)
            guard !Task.isCancelled else { return }
            binary = result
        }
    }

    @ViewBuilder private var buildNotice: some View {
        if variants != nil {
            if customized {
                Label("Non-default variants are built from source, which can take a while.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if binary == .available {
                Label("A pre-built binary is available, so this installs quickly.",
                      systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else if binary == .unavailable {
                Label("No pre-built binary was found for this Mac; it will be built from source.",
                      systemImage: "hammer").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        } else if let variants {
            if variants.isEmpty {
                Text("This port has no variants.").foregroundStyle(.secondary)
            } else {
                Text("Variants").font(.headline)
                List(variants) { variant in
                    Toggle(isOn: binding(for: variant)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("+" + variant.name).monospaced()
                            if !variant.summary.isEmpty {
                                Text(variant.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            if !variant.requires.isEmpty {
                                Text("Requires " + variant.requires.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !variant.conflicts.isEmpty {
                                Text("Conflicts with " + variant.conflicts.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 280)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// Turning a variant on also turns on what it requires and turns off what it conflicts with.
    private func binding(for variant: PortVariant) -> Binding<Bool> {
        Binding(
            get: { selected.contains(variant.name) },
            set: { on in
                if on {
                    selected.insert(variant.name)
                    selected.formUnion(variant.requires)
                    selected.subtract(variant.conflicts)
                } else {
                    selected.remove(variant.name)
                }
            })
    }
}
