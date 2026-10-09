import SwiftUI

/// The MacPorts logo, loaded from the app bundle's resources.
/// Loads `MacPortsLogo.svg` (or `.pdf` / `.png`) from `Sources/PortsApp/Resources/`;
/// an SF Symbol stands in if none is found. `size` is the height; width follows the aspect ratio.
struct MacPortsLogo: View {
    var size: CGFloat = 24

    private static let image: NSImage? = {
        for ext in ["svg", "pdf", "png"] {
            if let url = Bundle.module.url(forResource: "MacPortsLogo", withExtension: ext),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "shippingbox.fill").resizable().scaledToFit()
                    .foregroundStyle(.tint)
            }
        }
        .frame(height: size)
        .accessibilityLabel("MacPorts")
    }
}
