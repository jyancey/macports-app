import SwiftUI

/// The app icon, loaded from the bundled `AppIcon.png`.
struct AppIconImage: View {
  var size: CGFloat = 64

  var body: some View {
    Group {
      if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
        let image = NSImage(contentsOf: url)
      {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        Image(systemName: "shippingbox.fill").resizable().scaledToFit().foregroundStyle(.tint)
      }
    }
    .frame(width: size, height: size)
    .accessibilityLabel("MacPorts app icon")
  }
}
