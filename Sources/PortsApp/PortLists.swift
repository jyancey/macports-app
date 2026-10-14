// PortLists.swift - The Installed, Available, Outdated, Inactive, and Selections list views.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import PortsKit
import SwiftUI

// Each tab's list is its own view, so it only redraws when what it shows
// changes (rather than with everything ContentView reads), and computes its
// filtered rows once per redraw.

/// Title and count above a tab's content, with optional controls on the right.
struct PaneHeader<Accessory: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder var accessory: Accessory

  var body: some View {
    HStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.title2.weight(.semibold))
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      accessory
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }
}

extension Int64 {
  /// "12.3 MB", in file-size units like Finder's.
  var fileSize: String { formatted(.byteCount(style: .file)) }
}

/// "1 result", "3 results": a count with its noun in the right number.
func counted(_ count: Int, _ singular: String, plural: String? = nil) -> String {
  "\(count.formatted()) " + (count == 1 ? singular : plural ?? singular + "s")
}

extension PaneHeader where Accessory == EmptyView {
  init(title: String, subtitle: String) {
    self.init(title: title, subtitle: subtitle) { EmptyView() }
  }
}

extension Array where Element == InstalledPort {
  /// Only the ports named in `leaves`; all of them when `leaves` is nil.
  func onlyLeaves(_ leaves: Set<String>?) -> [InstalledPort] {
    leaves.map { leaves in self.filter { leaves.contains($0.name) } } ?? self
  }

  /// Bytes the versions take up together; nil until at least one is measured.
  var totalUsage: Int64? {
    let measured = compactMap(\.diskUsage)
    return measured.isEmpty ? nil : measured.reduce(0, +)
  }

  /// "12 of 40", with the shown versions' size appended once it's known.
  func installedSubtitle(of total: Int) -> String {
    let count = "\(self.count) of \(total)"
    return totalUsage.map { "\(count) · \($0.fileSize)" } ?? count
  }

  /// "3 inactive", with how much removing them would free once it's known.
  var inactiveSubtitle: String {
    let count = "\(self.count) inactive"
    return totalUsage.map { "\(count) · \($0.fileSize) can be freed" } ?? count
  }

  /// Ports whose name contains `filter` (all of them when it's empty).
  func matching(_ filter: String) -> [InstalledPort] {
    filter.isEmpty ? self : self.filter { $0.name.localizedCaseInsensitiveContains(filter) }
  }
}

/// A version's disk usage, right-aligned; "—" until measured.
struct SizeCell: View {
  let port: InstalledPort

  var body: some View {
    Text(port.diskUsage?.fileSize ?? "—")
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

struct InstalledListView: View {
  let model: InstalledPortsModel
  /// Marks ports that have a newer version.
  let outdated: OutdatedModel
  /// Passed in rather than read from the environment, like `activity` below.
  let actions: PortActions
  let filter: String
  /// Hide ports another installed port depends on.
  var leavesOnly = false
  @Binding var sortOrder: [KeyPathComparator<InstalledPort>]
  @Binding var selection: InstalledPort.ID?
  /// Opens Settings, where the `port` path is set.
  var showPortLocation: () -> Void = {}

  private static let installPage = URL(string: "https://www.macports.org/install.php")!

  var body: some View {
    let rows = model.ports.matching(filter).onlyLeaves(leavesOnly ? model.leaves : nil)
      .sorted(using: sortOrder)
    VStack(spacing: 0) {
      PaneHeader(
        title: "Installed Ports", subtitle: rows.installedSubtitle(of: model.ports.count))
      Group {
        if let error = model.errorMessage {
          LoadErrorView(title: "Can't read ports", message: error) {
            Task { await model.load() }
          } extraActions: {
            if model.isPortMissing {
              Link("Get MacPorts", destination: Self.installPage)
              Button("Set port Location…", action: showPortLocation)
            }
          }
        } else if model.isLoading && model.ports.isEmpty {
          ProgressView("Loading installed ports…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name).width(min: 120, ideal: 160)
            TableColumn("Version", value: \.version) { port in
              HStack(spacing: 4) {
                Text(port.version)
                if let update = outdated.update(for: port) {
                  Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Version \(update.availableVersion) is available")
                    .accessibilityLabel("Update available")
                }
              }
            }
            .width(min: 80, ideal: 100, max: 160)
            TableColumn("Variants") { Text($0.variants.map { "+" + $0 }.joined(separator: " ")) }
            TableColumn("Status") {
              Text($0.isActive ? "Active" : "Inactive")
                .foregroundStyle($0.isActive ? .primary : .secondary)
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("Size", value: \.sortUsage) { SizeCell(port: $0) }
              .width(min: 60, ideal: 80, max: 100)
          }
          .contextMenu(forSelectionType: InstalledPort.ID.self) { ids in
            if ids.count == 1, let port = model.ports.first(where: { ids.contains($0.id) }) {
              PortMenus.installedItems(port, update: outdated.update(for: port), actions: actions)
            }
          }
          .copyable(model.ports.filter { $0.id == selection }.map(\.name))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct InactiveListView: View {
  let model: InstalledPortsModel
  let actions: PortActions
  let filter: String
  @Binding var sortOrder: [KeyPathComparator<InstalledPort>]
  @Binding var selection: Set<InstalledPort.ID>

  var body: some View {
    let rows = model.ports.filter { !$0.isActive }.matching(filter).sorted(using: sortOrder)
    VStack(spacing: 0) {
      PaneHeader(title: "Inactive Ports", subtitle: rows.inactiveSubtitle)
      Group {
        if rows.isEmpty {
          ContentUnavailableView(
            "No inactive ports", systemImage: "archivebox",
            description: Text("Old versions left behind by upgrades appear here."))
        } else {
          Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name).width(min: 120, ideal: 160)
            TableColumn("Version") { Text("\($0.version)_\($0.revision)") }
              .width(min: 80, ideal: 100, max: 160)
            TableColumn("Variants") {
              Text($0.variants.map { "+" + $0 }.joined(separator: " ")).foregroundStyle(.secondary)
            }
            TableColumn("Size", value: \.sortUsage) { SizeCell(port: $0) }
              .width(min: 60, ideal: 80, max: 100)
          }
          .contextMenu(forSelectionType: InstalledPort.ID.self) { ids in
            let ports = rows.filter { ids.contains($0.id) }
            if ports.count == 1, let port = ports.first {
              PortMenus.installedItems(port, update: nil, actions: actions)
            } else if ports.count > 1 {
              PortMenus.copyNamesItem(ports.map(\.name))
              Divider()
              Button("Remove \(ports.count) Versions", role: .destructive) {
                Task { await actions.remove(ports) }
              }
              .disabled(actions.activity.isRunning)
            }
          }
          .copyable(rows.filter { selection.contains($0.id) }.map(\.name))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct SearchRow: Identifiable {
  let name: String
  let isInstalled: Bool
  var id: String { name }
}

/// Available-port search results. Doesn't depend on the search field's text,
/// so typing doesn't rebuild the rows; only a submitted search changes them.
struct SearchResultsView: View {
  let searchModel: SearchModel
  let installed: InstalledPortsModel
  /// Passed in rather than read from the environment: Table cells don't
  /// always get environment objects (rebuilding the rows crashed with "No
  /// Observable object of type ActivityLog found").
  let activity: ActivityLog
  let actions: PortActions
  let prebuiltOnly: Bool
  /// How the search term is matched; changing it reruns the search.
  @Binding var scope: SearchScope
  @Binding var selection: String?

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(
        title: "Available Ports", subtitle: counted(searchModel.results.count, "result")
      ) {
        Picker("Match", selection: $scope) {
          ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Choose how the search term is matched against available ports")
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder private var content: some View {
    if let error = searchModel.errorMessage {
      LoadErrorView(title: "Search failed", message: error) { searchModel.retry() }
    } else if searchModel.isSearching {
      ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if !searchModel.hasSearched {
      ContentUnavailableView(
        "Search MacPorts", systemImage: "magnifyingglass",
        description: Text("Type a name or keyword and press Return."))
    } else if searchModel.results.isEmpty {
      ContentUnavailableView.search(text: searchModel.searchedTerm)
    } else {
      // Only the "Pre-built only" filter reads the answers here; otherwise
      // each answer redraws just its own cell.
      let names =
        prebuiltOnly
        ? searchModel.results.filter { searchModel.binary[$0] == .available }
        : searchModel.results
      let rows = names.map { SearchRow(name: $0, isInstalled: installed.names.contains($0)) }
      Table(rows, selection: $selection) {
        TableColumn("Name", value: \.name).width(min: 120, ideal: 200)
        TableColumn("Pre-built") { row in
          BinaryHint(
            value: searchModel.binary[row.name],
            pending: searchModel.binaryCheckPending(row.name))
        }
        .width(min: 70, ideal: 80, max: 100)
        TableColumn("Status") { row in
          SearchStatus(progress: activity.progress[row.name], isInstalled: row.isInstalled)
        }
        .width(min: 90, ideal: 120)
      }
      .contextMenu(forSelectionType: String.self) { names in
        if names.count == 1, let name = names.first {
          PortMenus.copyItems(name: name, installCommand: "sudo port install \(name)")
          Divider()
          if installed.names.contains(name) {
            Button("Uninstall…", role: .destructive) { actions.requestUninstall(name) }
              .disabled(!actions.canStart(name))
          } else {
            Button("Install…") { Task { await actions.install(name) } }
              .disabled(!actions.canStart(name))
          }
        }
      }
      .copyable(selection.map { [$0] } ?? [])
    }
  }
}

/// Install progress or installed state for one search result.
struct SearchStatus: View {
  let progress: PortProgress?
  let isInstalled: Bool

  var body: some View {
    switch progress {
    case .working(let phase):
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(phase + "…")
      }
      .foregroundStyle(.tint)
    case .queued:
      Label("Waiting…", systemImage: "clock").foregroundStyle(.secondary)
    case .done:
      Label("Installed", systemImage: "shippingbox.fill").foregroundStyle(.secondary)
    case nil:
      Label(
        isInstalled ? "Installed" : "Not installed",
        systemImage: isInstalled ? "shippingbox.fill" : "shippingbox"
      )
      .foregroundStyle(.secondary)
    }
  }
}

/// A load or search error in place of a list, with Try Again and any other
/// ways to fix it.
struct LoadErrorView<Extra: View>: View {
  let title: String
  let message: String
  let retry: () -> Void
  @ViewBuilder var extraActions: Extra

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Try Again", action: retry)
      extraActions
    }
  }
}

extension LoadErrorView where Extra == EmptyView {
  init(title: String, message: String, retry: @escaping () -> Void) {
    self.init(title: title, message: message, retry: retry) { EmptyView() }
  }
}

/// The Pre-built column: a seal, a dash, a question mark, or a spinner while checking.
struct BinaryHint: View {
  let value: BinaryAvailability?
  let pending: Bool

  var body: some View {
    switch value {
    case .available:
      Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        .help("A pre-built binary exists for this Mac")
        .accessibilityLabel("Pre-built binary available")
    case .unavailable:
      Text("–").foregroundStyle(.secondary).help("No pre-built binary found; builds from source")
        .accessibilityLabel("Builds from source")
    case .unknown:
      Text("?").foregroundStyle(.secondary).help("Couldn't reach the archive server")
        .accessibilityLabel("Pre-built status unknown")
    case nil:
      if pending {
        ProgressView().controlSize(.mini)
          .accessibilityLabel("Checking for a pre-built binary")
      } else {
        Text("")
      }
    }
  }
}

struct OutdatedListView: View {
  let model: OutdatedModel
  let actions: PortActions
  let filter: String
  let prebuiltOnly: Bool
  @Binding var selection: Set<OutdatedPort.ID>

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Outdated Ports", subtitle: "\(model.ports.count) outdated")
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder private var content: some View {
    if let error = model.errorMessage {
      LoadErrorView(title: "Can't check for updates", message: error) {
        Task { await model.load() }
      }
    } else if model.isLoading && model.ports.isEmpty {
      ProgressView("Checking…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.ports.isEmpty {
      ContentUnavailableView(
        "Everything is up to date", systemImage: "checkmark.circle",
        description: Text("No installed ports have newer versions."))
    } else {
      let rows = model.ports.filter {
        (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter))
          && (!prebuiltOnly || model.binary[$0.name] == .available)
      }
      Table(rows, selection: $selection) {
        TableColumn("Name", value: \.name).width(min: 110, ideal: 150)
        TableColumn("Installed", value: \.installedVersion).width(min: 70, ideal: 90, max: 140)
        TableColumn("Available", value: \.availableVersion).width(min: 70, ideal: 90, max: 140)
      }
      .contextMenu(forSelectionType: OutdatedPort.ID.self) { ids in
        let names = rows.filter { ids.contains($0.id) }.map(\.name)
        if names.count == 1, let name = names.first {
          PortMenus.copyItems(name: name, installCommand: nil)
          Divider()
          Button("Upgrade") { Task { await actions.upgrade(name) } }
            .disabled(!actions.canStart(name))
        } else if names.count > 1 {
          PortMenus.copyNamesItem(names)
          Divider()
          Button("Upgrade \(names.count) Ports") { Task { await actions.upgrade(names) } }
            .disabled(actions.activity.isRunning)
        }
      }
      .copyable(rows.filter { selection.contains($0.id) }.map(\.name))
    }
  }
}

struct SelectionsListView: View {
  let model: SelectionsModel
  @Binding var selection: String?

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Selections", subtitle: counted(model.groups.count, "group"))
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder private var content: some View {
    if let error = model.errorMessage {
      LoadErrorView(title: "Can't read selections", message: error) {
        Task { await model.load() }
      }
    } else if model.isLoading && model.groups.isEmpty {
      ProgressView("Loading selections…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.groups.isEmpty {
      ContentUnavailableView(
        "No selection groups", systemImage: "arrow.left.arrow.right.circle",
        description: Text("Install ports such as clang or python to choose between versions."))
    } else {
      Table(model.groups, selection: $selection) {
        TableColumn("Group", value: \.name).width(min: 100, ideal: 140)
        // Changing the selection happens in the detail pane; this shows a
        // choice being applied there until the reload confirms it.
        TableColumn("Selected") { group in
          let selected = model.shownSelection(group)
          if selected == "none" {
            Text("None").foregroundStyle(.secondary)
          } else {
            Text(selected)
          }
        }
      }
    }
  }
}

/// The Activity log with its resizable divider. It owns the drag state, so
/// dragging redraws only this pane.
struct ActivityPane: View {
  @AppStorage("activityHeight") private var activityHeight: Double = 200
  @State private var dragPreview: Double?

  var body: some View {
    VStack(spacing: 0) {
      Divider()
        .overlay(
          Color.clear.frame(height: 8).contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
            .gesture(
              DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                  dragPreview = min(600, max(80, activityHeight - v.translation.height))
                }
                .onEnded { _ in
                  if let h = dragPreview { activityHeight = h }
                  dragPreview = nil
                })
        )
        .overlay(alignment: .top) {
          if let h = dragPreview {
            Rectangle().fill(Color.accentColor).frame(height: 2)
              .overlay(alignment: .trailing) {
                Text("\(Int(h)) pt").font(.caption2).padding(2)
                  .background(.regularMaterial)
                  .offset(y: -14)
              }
              .offset(y: activityHeight - h)
          }
        }
      ActivityLogView(height: activityHeight)
    }
  }
}
