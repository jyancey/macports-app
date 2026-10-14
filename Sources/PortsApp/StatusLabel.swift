// StatusLabel.swift - A status message with a coloured icon.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import PortsKit
import SwiftUI

/// The ports tree's last sync, under the Available and Outdated lists, whose
/// results come from it. When it is old, says so and offers Sync.
struct PortsTreeSyncBar: View {
  let status: MacPortsInfo.SyncStatus
  let isBusy: Bool
  let sync: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      switch status {
      case .unknown:
        StatusLabel(
          "Ports tree: last sync unknown", systemImage: "questionmark.circle", color: .secondary)
      case .fresh(let date):
        StatusLabel(
          "Ports tree: last synced \(Self.age(date))", systemImage: "checkmark.circle.fill",
          color: .green)
      case .stale(let date):
        StatusLabel(
          "Ports tree: last synced \(Self.age(date)). Results may be out of date.",
          systemImage: "exclamationmark.triangle.fill", color: .orange)
      }
      Spacer()
      if !isFresh {
        Button("Sync Now", action: sync).disabled(isBusy)
      }
    }
    .font(.callout)
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }

  private var isFresh: Bool {
    if case .fresh = status { return true }
    return false
  }

  /// "3 days ago", "yesterday".
  static func age(_ date: Date) -> String {
    date.formatted(.relative(presentation: .named, unitsStyle: .wide))
  }
}

/// A status message whose icon carries the colour. The text keeps the normal
/// label colour, because green or orange text on a light background is hard
/// to read.
struct StatusLabel: View {
  let text: String
  let systemImage: String
  let color: Color

  init(_ text: String, systemImage: String, color: Color) {
    self.text = text
    self.systemImage = systemImage
    self.color = color
  }

  var body: some View {
    Label {
      Text(text)
    } icon: {
      Image(systemName: systemImage).foregroundStyle(color)
    }
  }
}
