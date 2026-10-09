import SwiftUI
import PortsKit

/// Output of the long-running commands the app starts (install, and later uninstall/upgrade).
@MainActor
@Observable
final class ActivityLog {
    private(set) var lines: [String] = []
    private(set) var isRunning = false
    private(set) var runningName: String?
    var isVisible = false

    private static let maxLines = 5000

    /// Runs `work`, streaming its output into the log. Returns true on success.
    /// Only one command runs at a time; a second request is ignored.
    @discardableResult
    func run(_ title: String, name: String,
             work: (@escaping @MainActor @Sendable (String) -> Void) async throws -> Void) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        runningName = name
        isVisible = true
        append("$ \(title)\n")
        defer { isRunning = false; runningName = nil }
        do {
            try await work { [weak self] text in self?.append(text) }
            append("✓ Finished\n\n")
            return true
        } catch PortClientError.cancelled {
            append("Cancelled\n\n")
        } catch {
            append("✗ \(error.localizedDescription)\n\n")
        }
        return false
    }

    func clear() { lines.removeAll() }

    private func append(_ text: String) {
        var new = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { new.removeLast() }
        lines.append(contentsOf: new)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }
}

struct ActivityLogView: View {
    @Environment(ActivityLog.self) private var log

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Activity", systemImage: "terminal")
                    .font(.headline)
                if log.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Clear", systemImage: "trash") { log.clear() }
                    .disabled(log.lines.isEmpty || log.isRunning)
                Button("Hide", systemImage: "chevron.down") { log.isVisible = false }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .textSelection(.enabled)
                    .padding(8)
                }
                .onChange(of: log.lines.count) { proxy.scrollTo("end") }
                .overlay {
                    if log.lines.isEmpty {
                        Text("No activity yet").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 200)
        .background(.background)
    }
}
