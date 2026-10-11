import AppKit
import PortsKit
import SwiftUI

/// Output of the long-running commands the app starts (install, and later uninstall/upgrade).
@MainActor
@Observable
final class ActivityLog {
  /// The output, in the chunks it arrived in, so the text view can append just
  /// what is new. `chunks[0]` is chunk number `firstChunk`; numbers only grow.
  private(set) var chunks: [String] = []
  private(set) var firstChunk = 0
  /// Changes whenever the output does.
  private(set) var revision = 0
  private(set) var lineCount = 0
  private(set) var isRunning = false
  /// True when the most recent run ended in an error.
  private(set) var lastRunFailed = false
  private(set) var runningName: String?
  /// Counts finished runs. Any run may have changed the system, so cached tab
  /// data watches this to know when it is out of date.
  private(set) var completedRuns = 0
  var isVisible = false
  /// Live status of each port the current run is touching, including dependencies.
  private(set) var progress: [String: PortProgress] = [:]
  private var parser = InstallProgressParser()
  @ObservationIgnored private var chunkLines: [Int] = []
  private let maxLines: Int

  static let autoOpenKey = "autoOpenActivity"

  /// Past `maxLines`, the oldest output is dropped (whole chunks, keeping the newest).
  init(maxLines: Int = 5000) {
    self.maxLines = maxLines
  }

  var isEmpty: Bool { chunks.isEmpty }

  /// Runs `work`, streaming its output into the log. Returns true on success.
  /// Only one command runs at a time; a second request is ignored.
  @discardableResult
  func run(
    _ title: String, name: String,
    work: (@escaping @MainActor @Sendable (String) -> Void) async throws -> Void
  ) async -> Bool {
    guard !isRunning else { return false }
    isRunning = true
    lastRunFailed = false
    runningName = name
    if UserDefaults.standard.object(forKey: Self.autoOpenKey) as? Bool ?? true { isVisible = true }
    append("$ \(title)\n")
    parser = InstallProgressParser()
    progress = [:]
    defer {
      isRunning = false
      runningName = nil
      progress = [:]
      completedRuns += 1
    }
    do {
      try await work { [weak self] text in self?.append(text) }
      append("✓ Finished\n\n")
      return true
    } catch PortClientError.cancelled {
      append("Cancelled\n\n")
    } catch {
      lastRunFailed = true
      append("✗ \(error.localizedDescription)\n\n")
    }
    return false
  }

  func clear() {
    firstChunk += chunks.count
    chunks.removeAll()
    chunkLines.removeAll()
    lineCount = 0
    lastRunFailed = false
    revision += 1
  }

  private func append(_ text: String) {
    if isRunning {
      parser.consume(text)
      if parser.statuses != progress { progress = parser.statuses }
    }
    guard !text.isEmpty else { return }
    let lines = text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    chunks.append(text)
    chunkLines.append(lines)
    lineCount += lines
    while lineCount > maxLines, chunks.count > 1 {
      lineCount -= chunkLines.removeFirst()
      chunks.removeFirst()
      firstChunk += 1
    }
    revision += 1
  }
}

/// Brings a text storage in line with the log by appending new chunks and
/// deleting dropped ones from the front, never rebuilding the whole text.
struct LogTextSync {
  /// Number of the first chunk in the storage, and the length (UTF-16) of
  /// each chunk the storage holds, in order.
  private(set) var firstChunk = 0
  private(set) var lengths: [Int] = []

  mutating func apply(
    chunks: [String], firstChunk modelFirst: Int, to storage: NSTextStorage,
    attributes: [NSAttributedString.Key: Any]
  ) {
    storage.beginEditing()
    defer { storage.endEditing() }
    var dropped = 0
    while firstChunk < modelFirst, !lengths.isEmpty {
      dropped += lengths.removeFirst()
      firstChunk += 1
    }
    if lengths.isEmpty { firstChunk = max(firstChunk, modelFirst) }
    if dropped > 0 { storage.deleteCharacters(in: NSRange(location: 0, length: dropped)) }
    let shownEnd = firstChunk + lengths.count
    for number in max(shownEnd, modelFirst)..<(modelFirst + chunks.count) {
      let chunk = chunks[number - modelFirst]
      storage.append(NSAttributedString(string: chunk, attributes: attributes))
      lengths.append((chunk as NSString).length)
    }
  }
}

/// The log in a read-only `NSTextView`: appending is cheap, text can be
/// selected across lines, and it follows new output while scrolled to the
/// bottom (and stays put when the reader has scrolled up).
struct LogTextView: NSViewRepresentable {
  let log: ActivityLog
  /// Read here so SwiftUI updates the view whenever the output changes.
  let revision: Int

  final class Coordinator {
    var sync = LogTextSync()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView { MonospacedTextView.makeScrollView() }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    Self.update(scrollView, from: log, sync: &context.coordinator.sync)
  }

  static func update(_ scrollView: NSScrollView, from log: ActivityLog, sync: inout LogTextSync) {
    guard let textView = scrollView.documentView as? NSTextView,
      let storage = textView.textStorage
    else { return }
    let followOutput = isScrolledToBottom(scrollView)
    sync.apply(
      chunks: log.chunks, firstChunk: log.firstChunk, to: storage,
      attributes: MonospacedTextView.attributes)
    if followOutput { textView.scrollToEndOfDocument(nil) }
  }

  static func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
    guard let document = scrollView.documentView else { return true }
    let visible = scrollView.contentView.bounds
    return visible.maxY >= document.frame.maxY - 4
  }
}

struct ActivityLogView: View {
  var height: Double = 200
  @Environment(ActivityLog.self) private var log

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Activity", systemImage: "terminal")
          .font(.headline)
        Circle()
          .fill(log.isRunning ? Color.yellow : log.lastRunFailed ? Color.red : Color.green)
          .frame(width: 10, height: 10)
          .help(log.isRunning ? "Busy" : log.lastRunFailed ? "Last command failed" : "Ready")
        Spacer()
        Button("Clear", systemImage: "trash") { log.clear() }
          .disabled(log.isEmpty || log.isRunning)
        Button("Hide", systemImage: "chevron.down") { log.isVisible = false }
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 12).padding(.vertical, 6)
      Divider()
      LogTextView(log: log, revision: log.revision)
        .overlay {
          if log.isEmpty {
            Text("No activity yet").foregroundStyle(.secondary)
          }
        }
    }
    .frame(height: height)
    .background(.background)
  }
}
