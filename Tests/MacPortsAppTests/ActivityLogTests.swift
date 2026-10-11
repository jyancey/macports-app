import AppKit
import PortsKit
import Testing

@testable import MacPortsApp

@MainActor
@Suite struct ActivityLogTests {
  /// Runs one command whose output is `chunks`.
  func run(_ log: ActivityLog, _ chunks: [String], failing: Bool = false) async {
    await log.run("port test", name: "test") { out in
      for chunk in chunks { out(chunk) }
      if failing { throw PortClientError.commandFailed(status: 1, stderr: "boom") }
    }
  }

  func text(_ log: ActivityLog) -> String { log.chunks.joined() }

  @Test func recordsTheCommandAndItsOutput() async {
    let log = ActivityLog()
    await run(log, ["one\n", "two\nthree\n"])
    #expect(text(log) == "$ port test\none\ntwo\nthree\n✓ Finished\n\n")
    #expect(log.lineCount == 6)
    #expect(!log.lastRunFailed)
  }

  @Test func failureIsRecorded() async {
    let log = ActivityLog()
    await run(log, ["one\n"], failing: true)
    #expect(text(log).hasSuffix("✗ port exited with status 1: boom\n\n"))
    #expect(log.lastRunFailed)
  }

  @Test func oldestOutputIsDroppedPastTheLimit() async {
    let log = ActivityLog(maxLines: 10)
    await run(log, (1...30).map { "line \($0)\n" })
    #expect(log.lineCount <= 10)
    #expect(text(log).hasSuffix("line 30\n✓ Finished\n\n"))
    #expect(!text(log).contains("line 20\n"))
    #expect(log.firstChunk > 0)
  }

  @Test func clearEmptiesTheLogButKeepsNumbering() async {
    let log = ActivityLog()
    await run(log, ["one\n"])
    let next = log.firstChunk + log.chunks.count
    log.clear()
    #expect(log.isEmpty)
    #expect(log.lineCount == 0)
    #expect(log.firstChunk == next)
  }

  @Test func failureOpensThePaneEvenWithAutoOpenOff() async {
    let defaults = UserDefaults.standard
    let saved = defaults.object(forKey: ActivityLog.autoOpenKey)
    defaults.set(false, forKey: ActivityLog.autoOpenKey)
    defer { defaults.set(saved, forKey: ActivityLog.autoOpenKey) }

    let log = ActivityLog()
    await run(log, ["one\n"])
    #expect(!log.isVisible)
    await run(log, [], failing: true)
    #expect(log.isVisible)
  }

  @Test func runningCommandAndStartAreKnownWhileItRuns() async throws {
    let log = ActivityLog()
    let gates = Gates()
    let before = Date()
    let run = Task {
      await log.run("sudo port install zlib", name: "zlib") { _ in try await gates.pass("run") }
    }
    #expect(try await until { log.isRunning })
    #expect(log.runningTitle == "sudo port install zlib")
    #expect(log.startedAt.map { $0 >= before } == true)
    await gates.open("run")
    await run.value
    #expect(log.runningTitle == nil)
    #expect(log.startedAt == nil)
  }

  // MARK: Stop

  /// A command that runs until it is asked to stop, then fails the way an
  /// interrupted `port` does.
  func runUntilStopped(_ log: ActivityLog) async {
    await log.run("port build", name: "build") { out in
      guard let stop = CommandStop.current else {
        Issue.record("the command was not given a stop")
        return
      }
      out("building\n")
      while !stop.isRequested { try await Task.sleep(for: .milliseconds(2)) }
      throw PortClientError.commandFailed(status: 130, stderr: "")
    }
  }

  @Test func stoppedRunIsReportedAsStopped() async throws {
    let log = ActivityLog()
    #expect(!log.canStop)
    let run = Task { await runUntilStopped(log) }
    #expect(try await until { text(log).contains("building") })
    #expect(log.canStop)
    log.requestStop()
    #expect(log.isStopping && !log.canStop)
    await run.value
    #expect(text(log).hasSuffix("building\nStopping…\nStopped\n\n"))
    #expect(!log.lastRunFailed)
    #expect(!log.isStopping && !log.canStop)
  }

  @Test func failureWithoutAStopIsStillAFailure() async {
    let log = ActivityLog()
    await run(log, [], failing: true)
    #expect(log.lastRunFailed)
    #expect(!text(log).contains("Stopped"))
  }

  @Test func eachRunGetsItsOwnStop() async throws {
    let log = ActivityLog()
    let first = Task { await runUntilStopped(log) }
    #expect(try await until { log.canStop })
    log.requestStop()
    await first.value
    // The next run is not stopped by the earlier request.
    await run(log, ["two\n"])
    #expect(text(log).hasSuffix("two\n✓ Finished\n\n"))
  }

  // MARK: Text view

  func storageText(_ storage: NSTextStorage) -> String { storage.string }

  @Test func textStorageFollowsAppendsTrimsAndClears() async {
    let log = ActivityLog(maxLines: 6)
    let storage = NSTextStorage()
    var sync = LogTextSync()
    func apply() {
      sync.apply(
        chunks: log.chunks, firstChunk: log.firstChunk, to: storage,
        attributes: MonospacedTextView.attributes)
      #expect(storageText(storage) == text(log))
    }

    await run(log, ["a\n", "b\n"])
    apply()
    // Output arrives in several chunks between view updates, and old output is trimmed.
    await run(log, ["c\n", "d\n", "e\n", "f\n"])
    apply()
    #expect(!storageText(storage).contains("a\n"))
    log.clear()
    apply()
    #expect(storageText(storage).isEmpty)
    await run(log, ["g\n"])
    apply()
  }

  /// Trimmed output the view never showed must not be deleted from it.
  @Test func outputTrimmedBeforeItWasShownIsSkipped() async {
    let log = ActivityLog(maxLines: 3)
    let storage = NSTextStorage()
    var sync = LogTextSync()
    await run(log, (1...20).map { "line \($0)\n" })
    sync.apply(
      chunks: log.chunks, firstChunk: log.firstChunk, to: storage,
      attributes: MonospacedTextView.attributes)
    #expect(storageText(storage) == text(log))
  }

  // MARK: Following output

  func makeView() -> NSScrollView {
    let scrollView = MonospacedTextView.makeScrollView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
    return scrollView
  }

  func scrollToTop(_ scrollView: NSScrollView) {
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  @Test func followsNewOutputOnlyWhileAtTheBottom() async {
    let log = ActivityLog()
    let view = makeView()
    var sync = LogTextSync()
    await run(log, (1...200).map { "line \($0)\n" })
    LogTextView.update(view, from: log, sync: &sync)
    // The text is taller than the view, so scrolling is real.
    #expect((view.documentView?.frame.height ?? 0) > 1000)
    #expect(view.contentView.bounds.minY > 0)
    #expect(LogTextView.isScrolledToBottom(view))

    scrollToTop(view)
    await run(log, (1...50).map { "more \($0)\n" })
    LogTextView.update(view, from: log, sync: &sync)
    #expect(view.contentView.bounds.minY == 0)
  }

  /// The old log stopped scrolling once it held its maximum number of lines.
  @Test func keepsFollowingAfterReachingTheLimit() async {
    let log = ActivityLog(maxLines: 100)
    let view = makeView()
    var sync = LogTextSync()
    for round in 1...5 {
      await run(log, (1...60).map { "round \(round) line \($0)\n" })
      LogTextView.update(view, from: log, sync: &sync)
      #expect(view.contentView.bounds.minY > 0)
      #expect(LogTextView.isScrolledToBottom(view))
    }
    #expect(log.firstChunk > 0)
  }
}
