import PortsKit
import SwiftUI

@MainActor
@Observable
final class PortDetailModel {
  enum Loadable<T: Sendable>: Sendable {
    case loading
    case loaded(T)
    case failed(String)
  }

  typealias BinaryCheck =
    @Sendable (_ name: String, _ version: String, _ revision: Int, _ variants: [String]) async ->
    BinaryAvailability

  var info: Loadable<PortInfo> = .loading
  var files: Loadable<[String]> = .loading
  var dependents: Loadable<[String]> = .loading
  /// The full recursive tree of `treeName`; nil until requested. `port rdeps`
  /// can take tens of seconds, so it only runs when the tree is expanded.
  private(set) var tree: Loadable<[PortInfoParser.DependencyNode]>?
  private(set) var treeName: String?
  /// Whether a pre-built archive exists for the default variants; nil until checked.
  var binary: BinaryAvailability?

  private let source: any PortDetailSource
  private let binaryCheck: BinaryCheck
  private let debounce: Duration

  /// `debounce` delays the first query so that moving quickly through a list
  /// doesn't start `port` for every row passed over.
  init(
    source: any PortDetailSource = PortClient(),
    binaryCheck: @escaping BinaryCheck = BinaryArchive.availability,
    debounce: Duration = .milliseconds(120)
  ) {
    self.source = source
    self.binaryCheck = binaryCheck
    self.debounce = debounce
  }

  private enum Piece: Sendable {
    case info(Loadable<PortInfo>)
    case files(Loadable<[String]>)
    case dependents(Loadable<[String]>)
    case variants([PortVariant]?)
    case binary(BinaryAvailability)
  }

  /// Loads everything but the dependency tree, showing each result as soon as
  /// it arrives. Files and dependents are only queried for installed ports.
  func load(_ name: String, isInstalled: Bool) async {
    info = .loading
    files = isInstalled ? .loading : .loaded([])
    dependents = isInstalled ? .loading : .loaded([])
    binary = nil
    if debounce > .zero { try? await Task.sleep(for: debounce) }
    guard !Task.isCancelled else { return }

    let source = self.source
    let binaryCheck = self.binaryCheck
    await withTaskGroup(of: Piece.self) { group in
      group.addTask { .info(await Self.capture { try await source.info(for: name) }) }
      group.addTask { .variants(try? await source.variants(of: name)) }
      if isInstalled {
        group.addTask { .files(await Self.capture { try await source.contents(of: name) }) }
        group.addTask {
          .dependents(await Self.capture { try await source.dependents(of: name) })
        }
      }
      // The binary check starts once both the version (info) and the default
      // variants are known, without waiting for files or dependents.
      var loadedInfo: PortInfo?
      var defaults: [String]?
      var checkStarted = false
      while let piece = await group.next() {
        guard !Task.isCancelled else {
          group.cancelAll()
          return
        }
        switch piece {
        case .info(let result):
          info = result
          if case .loaded(let value) = result { loadedInfo = value }
        case .files(let result): files = result
        case .dependents(let result): dependents = result
        case .variants(let found): defaults = (found ?? []).filter(\.isDefault).map(\.name)
        case .binary(let result): binary = result
        }
        if !checkStarted, let info = loadedInfo, let defaults {
          checkStarted = true
          group.addTask {
            .binary(await binaryCheck(name, info.version, info.revision, defaults))
          }
        }
      }
    }
  }

  /// The dependency tree, if it belongs to `name`.
  func tree(for name: String) -> Loadable<[PortInfoParser.DependencyNode]>? {
    treeName == name ? tree : nil
  }

  /// Loads the dependency tree of `name` unless it is loaded already.
  func loadTree(_ name: String) async {
    if treeName == name, case .loaded = tree { return }
    treeRequest += 1
    let request = treeRequest
    treeName = name
    tree = .loading
    let source = self.source
    let result = await Self.capture { try await source.dependencyTree(of: name) }
    // A newer request owns the tree now. Collapsing the tree cancels the
    // query; leave it to be requested again.
    guard request == treeRequest else { return }
    tree = Task.isCancelled ? nil : result
  }

  private var treeRequest = 0

  nonisolated private static func capture<T: Sendable>(
    _ work: @Sendable () async throws -> T
  ) async -> Loadable<T> {
    do { return .loaded(try await work()) } catch { return .failed(error.localizedDescription) }
  }
}

extension PortDetailModel.Loadable: Equatable where T: Equatable {}

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
  /// Called when the user clicks a dependency name to jump to that port.
  var onOpenPort: (String) -> Void = { _ in }
  @Environment(ActivityLog.self) private var activity
  @State private var model = PortDetailModel()
  /// The port whose dependency tree is expanded; showing another port collapses it.
  @State private var expandedTree: String?

  /// Installing flips `isInstalled`, which reloads to pick up the files.
  private struct LoadKey: Hashable {
    let name: String
    let isInstalled: Bool
  }

  private var treeExpanded: Binding<Bool> {
    Binding(get: { expandedTree == name }, set: { expandedTree = $0 ? name : nil })
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        infoSection
        dependentsSection
        treeSection
        filesSection
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: LoadKey(name: name, isInstalled: isInstalled)) {
      await model.load(name, isInstalled: isInstalled)
    }
    // Collapsing the tree or showing another port cancels `port rdeps`.
    .task(id: expandedTree == name ? name : nil) {
      if expandedTree == name { await model.loadTree(name) }
    }
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
      Text(
        "This removes the port from your system. macOS administrator authorization will be requested.")
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
      if ok { await onInstalled() }
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
          portRow("Library deps", info.libDependencies)
          portRow("Build deps", info.buildDependencies)
          portRow("Runtime deps", info.runDependencies)
        }
      }
    }
  }

  @ViewBuilder private var dependentsSection: some View {
    if case .loaded(let names) = model.dependents, !names.isEmpty {
      DisclosureGroup("Required by (\(names.count))") {
        portLinks(names)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// Shown for ports with dependencies; `port rdeps` runs only while expanded.
  @ViewBuilder private var treeSection: some View {
    if case .loaded(let info) = model.info,
      !(info.libDependencies + info.buildDependencies + info.runDependencies).isEmpty
    {
      DisclosureGroup(isExpanded: treeExpanded) {
        Group {
          switch model.tree(for: name) {
          case .loaded(let nodes):
            VStack(alignment: .leading, spacing: 2) {
              ForEach(nodes) { TreeRow(node: $0, onOpenPort: onOpenPort) }
            }
          case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
          case .loading, nil:
            HStack(spacing: 6) {
              ProgressView().controlSize(.small)
              Text("Resolving dependencies… this can take a while.").foregroundStyle(.secondary)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        if case .loaded(let nodes) = model.tree(for: name) {
          Text("Full dependency tree (\(nodes.count) direct)")
        } else {
          Text("Full dependency tree")
        }
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

  /// Port names as clickable links that open the named port.
  private func portLinks(_ names: [String]) -> some View {
    var text = AttributedString()
    for (index, name) in names.enumerated() {
      if index > 0 { text.append(AttributedString(", ")) }
      var part = AttributedString(name)
      part.link = URL(string: "macports-port://" + name)
      text.append(part)
    }
    return Text(text).environment(
      \.openURL,
      OpenURLAction { url in
        guard url.scheme == "macports-port", let name = url.host(percentEncoded: false) else {
          return .systemAction
        }
        onOpenPort(name)
        return .handled
      })
  }

  @ViewBuilder private func portRow(_ title: String, _ names: [String]) -> some View {
    if !names.isEmpty {
      GridRow {
        label(title)
        portLinks(names)
      }
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
        Label(
          "Non-default variants are built from source, which can take a while.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
      } else if binary == .available {
        Label(
          "A pre-built binary is available, so this installs quickly.",
          systemImage: "checkmark.seal.fill"
        ).foregroundStyle(.green)
      } else if binary == .unavailable {
        Label(
          "No pre-built binary was found for this Mac; it will be built from source.",
          systemImage: "hammer"
        ).foregroundStyle(.secondary)
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

/// One expandable row of the dependency tree.
struct TreeRow: View {
  let node: PortInfoParser.DependencyNode
  let onOpenPort: (String) -> Void

  var body: some View {
    if let children = node.children {
      DisclosureGroup {
        ForEach(children) { TreeRow(node: $0, onOpenPort: onOpenPort) }
      } label: {
        link
      }
    } else {
      link
    }
  }

  private var link: some View {
    Button(node.name) { onOpenPort(node.name) }
      .buttonStyle(.link)
  }
}
