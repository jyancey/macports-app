// MonospacedTextView.swift - Read-only monospaced text views for the Activity log and installed file lists.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
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

/// A port's installed files as one text view, instead of one view per file
/// (python314 installs over 8,000). Grows with the list up to `maxHeight`,
/// then scrolls.
struct FileListView: NSViewRepresentable {
  let files: [String]
  var maxHeight: CGFloat = 300

  final class Coordinator {
    var shown: [String] = []
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = MonospacedTextView.makeScrollView()
    // One file per line, scrolling sideways for long paths, so the height
    // computed in sizeThatFits matches what is shown.
    if let textView = scrollView.documentView as? NSTextView {
      textView.isHorizontallyResizable = true
      textView.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      textView.textContainer?.widthTracksTextView = false
      textView.textContainer?.containerSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }
    scrollView.hasHorizontalScroller = true
    show(files, in: scrollView, coordinator: context.coordinator)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    // Arrays sharing storage compare in constant time, so this is cheap when
    // the list hasn't changed.
    guard files != context.coordinator.shown else { return }
    show(files, in: scrollView, coordinator: context.coordinator)
  }

  private func show(_ files: [String], in scrollView: NSScrollView, coordinator: Coordinator) {
    coordinator.shown = files
    let textView = scrollView.documentView as? NSTextView
    textView?.textStorage?.setAttributedString(
      NSAttributedString(
        string: files.joined(separator: "\n"), attributes: MonospacedTextView.attributes))
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize?
  {
    let lineHeight = NSLayoutManager().defaultLineHeight(for: MonospacedTextView.font)
    let height = CGFloat(files.count) * lineHeight + 2 * MonospacedTextView.inset.height
    return CGSize(width: proposal.width ?? 400, height: min(height, maxHeight))
  }
}
