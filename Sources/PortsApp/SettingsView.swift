// SettingsView.swift - The Settings window and its General, MacPorts, and Health panes.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import SwiftUI

/// The panes of the Settings window (⌘,).
enum SettingsPane: String {
  case general
  case macPorts
  case health

  /// Remembers the last pane, and lets other windows open a particular one.
  static let defaultsKey = "settingsPane"
}

/// App preferences, the MacPorts installation, and health checks.
struct SettingsView: View {
  @AppStorage(SettingsPane.defaultsKey) private var pane = SettingsPane.general
  let configuration: ConfigurationModel
  let health: HealthModel

  var body: some View {
    TabView(selection: $pane) {
      Tab("General", systemImage: "gearshape", value: .general) {
        GeneralSettingsView(configuration: configuration)
      }
      Tab("MacPorts", systemImage: "shippingbox", value: .macPorts) {
        MacPortsSettingsView(model: configuration)
      }
      Tab("Health", systemImage: "stethoscope", value: .health) {
        HealthView(model: health, configuration: configuration)
      }
    }
    .frame(width: 620, height: 520)
  }
}
