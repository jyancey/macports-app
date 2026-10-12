// PortMenus.swift - Context menu items and pasteboard helpers shared by the port tables.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import AppKit
import PortsKit
import SwiftUI

/// Copies text to the general pasteboard.
@MainActor
enum Pasteboard {
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

extension InstalledPort {
  /// The command that installs this port with the same variants.
  var installCommand: String {
    (["sudo port install", name] + variants.map { "+" + $0 }).joined(separator: " ")
  }
}

/// Context menu items shared by the port tables. Each takes the clicked or
/// selected rows; with no rows (a click on empty space) it shows nothing.
@MainActor
enum PortMenus {
  /// Copy Name, and Copy Install Command when `installCommand` is given.
  @ViewBuilder
  static func copyItems(name: String, installCommand: String?) -> some View {
    Button("Copy Name") { Pasteboard.copy(name) }
    if let installCommand {
      Button("Copy Install Command") { Pasteboard.copy(installCommand) }
    }
  }

  /// Copies several names, one per line.
  static func copyNamesItem(_ names: [String]) -> some View {
    Button("Copy Names") { Pasteboard.copy(names.joined(separator: "\n")) }
  }

  /// Items for one installed version: copy, then Upgrade/Uninstall for the
  /// active version or Activate/Remove for an inactive one.
  @ViewBuilder
  static func installedItems(
    _ port: InstalledPort, update: OutdatedPort?, actions: PortActions
  ) -> some View {
    copyItems(name: port.name, installCommand: port.installCommand)
    Divider()
    if port.isActive {
      if update != nil {
        Button("Upgrade") { Task { await actions.upgrade(port.name) } }
          .disabled(!actions.canStart(port.name))
      }
      Button("Uninstall…", role: .destructive) { actions.requestUninstall(port.name) }
        .disabled(!actions.canStart(port.name))
    } else {
      inactiveItems(port, actions: actions)
    }
  }

  @ViewBuilder
  static func inactiveItems(_ port: InstalledPort, actions: PortActions) -> some View {
    Button("Activate…") { actions.requestActivate(port) }
      .disabled(!actions.canStart(port.name))
    Button("Remove This Version", role: .destructive) { Task { await actions.remove(port) } }
      .disabled(!actions.canStart(port.name))
  }
}

/// The detail pane when several rows are selected: what they are, and one
/// action for all of them.
struct BatchSelectionView: View {
  let title: String
  let systemImage: String
  let items: [String]
  let actionTitle: String
  let actionImage: String
  var role: ButtonRole?
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(Self.summary(items))
    } actions: {
      Button(actionTitle, systemImage: actionImage, role: role, action: action)
        .buttonStyle(.borderedProminent)
        .disabled(isDisabled)
    }
  }

  /// One item per line, up to `limit`, then how many more there are.
  static func summary(_ items: [String], limit: Int = 12) -> String {
    let shown = items.prefix(limit).joined(separator: "\n")
    let rest = items.count - limit
    return rest > 0 ? shown + "\nand \(rest) more" : shown
  }
}
