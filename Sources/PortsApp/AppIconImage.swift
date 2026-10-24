// AppIconImage.swift - Shows the app icon loaded from the bundled AppIcon.png.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import SwiftUI

/// The app icon, loaded from the bundled `AppIcon.png`.
struct AppIconImage: View {
  var size: CGFloat = 64

  /// Read from disk once; the view is drawn on every redraw of the empty
  /// detail pane.
  @MainActor private static let icon: NSImage? = AppResources
    .url(forResource: "AppIcon", withExtension: "png")
    .flatMap(NSImage.init(contentsOf:))

  var body: some View {
    Group {
      if let image = Self.icon {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        Image(systemName: "shippingbox.fill").resizable().scaledToFit().foregroundStyle(.tint)
      }
    }
    .frame(width: size, height: size)
    .accessibilityLabel("MacPorts app icon")
  }
}
