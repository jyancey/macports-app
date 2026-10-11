import AppKit
import SwiftUI

/// Setup shared by the read-only monospaced text views (the Activity log and
/// a port's installed files). One `NSTextView` holds any amount of text
/// cheaply and lets it be selected across lines.
@MainActor
enum MonospacedTextView {
  static let font = NSFont.monospacedSystemFont(
    ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)

  static let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.labelColor,
  ]

  static let inset = NSSize(width: 8, height: 8)

  static func makeScrollView() -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    let textView = scrollView.documentView as! NSTextView
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.usesFindBar = true
    textView.drawsBackground = false
    textView.textContainerInset = inset
    scrollView.drawsBackground = false
    return scrollView
  }
}
