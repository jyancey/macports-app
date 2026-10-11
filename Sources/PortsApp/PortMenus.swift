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
