// PortClient.swift - Thin wrapper around the MacPorts `port` command line tool.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation

public enum PortClientError: LocalizedError {
  case notInstalled(String)
  case commandFailed(status: Int32, stderr: String)
  case unparseable(String)
  case invalidName(String)
  case invalidPattern(String)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .unparseable(let name):
      return "Couldn't read information for \(name)."
    case .invalidName(let name):
      return "\(name) is not a valid port name."
    case .invalidPattern(let pattern):
      return "\(pattern) is not a valid regular expression."
    case .cancelled:
      return "The operation was cancelled."
    case .notInstalled(let path):
      return "MacPorts was not found at \(path). Install it from macports.org."
    case .commandFailed(let status, let stderr):
      return "port exited with status \(status): \(stderr)"
    }
  }
}

/// Thin wrapper around the MacPorts `port` command line tool.
public struct PortClient: Sendable {
  public static let defaultExecutablePath = "/opt/local/bin/port"

  /// UserDefaults key for the "verbose output" preference.
  public static let verboseDefaultsKey = "verboseOutput"

  /// UserDefaults key for a custom `port` executable path. Empty or missing
  /// means the default.
  public static let executablePathDefaultsKey = "portExecutablePath"

  public static var configuredExecutablePath: String {
    let value =
      UserDefaults.standard.string(forKey: executablePathDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? defaultExecutablePath : value
  }

  /// Returns a problem description for a candidate `port` path, or nil if
  /// it is usable.
  public static func problem(withExecutablePath path: String) -> String? {
    guard isSafePath(path) else {
      return "Use an absolute path with only letters, numbers and / . _ -"
    }
    guard path.hasPrefix("/") else { return "The path must be absolute." }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      return "No file exists at this path."
    }
    guard FileManager.default.isExecutableFile(atPath: path) else {
      return "The file is not executable."
    }
    return nil
  }

  public let executableURL: URL
  /// Passes `-v` to long-running commands. Without it `port` still
  /// prints each `--->` step, just not the full build/configure output.
  public let verbose: Bool

  public init(
    executablePath: String = PortClient.configuredExecutablePath,
    verbose: Bool = UserDefaults.standard.bool(forKey: PortClient.verboseDefaultsKey)
  ) {
    self.executableURL = URL(fileURLWithPath: executablePath)
    self.verbose = verbose
  }

  public var isAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: executableURL.path)
  }

  /// The registry database for this MacPorts installation, if it can be read.
  var registry: PortRegistry? {
    let path = dataPath() + "/registry/registry.db"
    return FileManager.default.isReadableFile(atPath: path) ? PortRegistry(path: path) : nil
  }

  /// Reads the registry directly; if it can't be opened or queried, asks `port`.
  private func fromRegistry<T>(
    _ query: (PortRegistry) throws -> T, orRun fallback: () async throws -> T
  ) async throws -> T {
    if let registry, let result = try? query(registry) { return result }
    return try await fallback()
  }

  public func installedPorts() async throws -> [InstalledPort] {
    try await fromRegistry({ try $0.installedPorts() }, orRun: installedPortsFromCommand)
  }

  func installedPortsFromCommand() async throws -> [InstalledPort] {
    let output = try await run(["-q", "installed"])
    return PortListParser.parseInstalled(output)
  }

  /// Names of available ports matching `term` under `scope`, best matches first.
  public func search(_ term: String, scope: SearchScope = .name) async throws -> [String] {
    let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return [] }
    if scope == .regex, (try? NSRegularExpression(pattern: term)) == nil {
      throw PortClientError.invalidPattern(term)
    }
    let output = try await run(["-q", "search", "--line"] + scope.flags + ["--", term])
    return SearchRanking.sorted(PortInfoParser.parseNames(output), for: term)
  }

  public func info(for name: String) async throws -> PortInfo {
    let output = try await run(["-q", "info", "--line"] + PortInfoParser.fieldFlags + [name])
    guard let info = PortInfoParser.parse(output) else {
      throw PortClientError.unparseable(name)
    }
    return info
  }

  /// Files installed by the port (empty if the port isn't installed).
  public func contents(of name: String) async throws -> [String] {
    try await fromRegistry(
      { try $0.files(of: name) }, orRun: { try await contentsFromCommand(of: name) })
  }

  func contentsFromCommand(of name: String) async throws -> [String] {
    PortInfoParser.parseFileList(try await run(["-q", "contents", name]))
  }

  /// Installed ports that depend on the given port.
  public func dependents(of name: String) async throws -> [String] {
    try await fromRegistry(
      { try $0.dependents(of: name) }, orRun: { try await dependentsFromCommand(of: name) })
  }

  func dependentsFromCommand(of name: String) async throws -> [String] {
    PortInfoParser.parseDependents(try await run(["-q", "dependents", name]))
  }

  /// The full recursive dependency tree of a port.
  public func dependencyTree(of name: String) async throws -> [PortInfoParser.DependencyNode] {
    PortInfoParser.parseDependencyTree(try await run(["-q", "rdeps", name]))
  }

  /// Installs a port, streaming `port`'s output to `onOutput` as it is produced.
  /// `port install` needs root, so it runs through the standard macOS
  /// macOS administrator authorization prompt. That prompt can't stream output, so the
  /// command writes to a private log file that is tailed while it runs.
  public func install(
    _ name: String, variantFlags: [String] = [],
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    guard PortClient.isValidPortName(name) else { throw PortClientError.invalidName(name) }
    for flag in variantFlags where !PortClient.isValidVariantFlag(flag) {
      throw PortClientError.invalidName(flag)
    }
    try await runStreaming(
      action: "install", arguments: ([name] + variantFlags).joined(separator: " "),
      onOutput: onOutput)
  }

  /// Variants the port offers, with defaults and requirements.
  public func variants(of name: String) async throws -> [PortVariant] {
    guard PortClient.isValidPortName(name) else { throw PortClientError.invalidName(name) }
    return PortVariantParser.parse(try await run(["-q", "variants", name]))
  }

  /// Uninstalls a port (fails, with `port`'s explanation in the output, if
  /// other ports depend on it).
  public func uninstall(
    _ name: String,
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    try await runStreaming(action: "uninstall", name: name, onOutput: onOutput)
  }

  /// Ports with a newer version available.
  public func outdated() async throws -> [OutdatedPort] {
    OutdatedParser.parse(try await run(["-q", "outdated"]))
  }

  /// Upgrades one port (and whatever it needs).
  public func upgrade(
    _ name: String,
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    try await upgrade([name], onOutput: onOutput)
  }

  /// Upgrades several ports in one command (one authorization prompt).
  public func upgrade(
    _ names: [String],
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    guard !names.isEmpty else { return }
    for name in names where !PortClient.isValidPortName(name) {
      throw PortClientError.invalidName(name)
    }
    try await runStreaming(
      action: "upgrade", arguments: names.joined(separator: " "), onOutput: onOutput)
  }

  /// Upgrades every outdated port.
  public func upgradeAll(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
    try await runStreaming(action: "upgrade", name: "outdated", onOutput: onOutput)
  }

  /// Uninstalls one specific installed version of a port (used to remove
  /// inactive versions).
  public func uninstall(
    _ port: InstalledPort,
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    try await uninstall([port], onOutput: onOutput)
  }

  /// Uninstalls several specific installed versions in one command (one
  /// authorization prompt).
  public func uninstall(
    _ ports: [InstalledPort],
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    guard !ports.isEmpty else { return }
    try await runStreaming(
      action: "uninstall", arguments: try PortClient.versionArguments(ports), onOutput: onOutput)
  }

  /// Activates one specific installed version of a port. `port` deactivates
  /// the version that is active now first; it stays installed.
  public func activate(
    _ port: InstalledPort,
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    try await runStreaming(action: "activate", port: port, onOutput: onOutput)
  }

  /// Uninstalls every inactive version of every port.
  public func uninstallInactive(onOutput: @escaping @MainActor @Sendable (String) -> Void)
    async throws
  {
    try await runStreaming(action: "uninstall", name: "inactive", onOutput: onOutput)
  }

  /// Every `port select` group with its current selection
  /// (`port select --summary`).
  public func selections() async throws -> [PortSelectGroup] {
    PortSelectParser.parse(try await run(["select", "--summary"]))
  }

  /// Selects `option` for `group`; "none" unsets it (`port select --set`).
  public func setSelection(
    group: String, option: String,
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    guard PortClient.isValidPortName(group) else { throw PortClientError.invalidName(group) }
    guard PortClient.isValidPortName(option) else { throw PortClientError.invalidName(option) }
    try await runStreaming(
      action: "select", arguments: "--set \(group) \(option)", onOutput: onOutput)
  }

  /// Runs `port diagnose` and returns its findings; warnings arrive on
  /// stderr, so both streams are read.
  public func diagnoseFindings() async throws -> [DiagnosticFinding] {
    DiagnoseParser.parse(try await run(["diagnose"], mergeStderr: true))
  }

  /// Opens Terminal running `port reclaim`, which is interactive and asks
  /// before removing anything.
  public func reclaimInTerminal() async throws {
    guard isAvailable, PortClient.isSafePath(executableURL.path) else {
      throw PortClientError.invalidName(executableURL.path)
    }
    let command = "sudo \(executableURL.path) reclaim"
    _ = try await ChildProcess.run(
      URL(fileURLWithPath: "/usr/bin/osascript"),
      arguments: [
        "-e", "tell application \"Terminal\" to activate",
        "-e", "tell application \"Terminal\" to do script \"\(command)\"",
      ])
  }

  /// Updates MacPorts itself and syncs the ports tree (`port selfupdate`).
  public func selfupdate(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
    try await runStreaming(action: "selfupdate", arguments: "", onOutput: onOutput)
  }

  /// Syncs the ports tree only, without updating MacPorts (`port sync`).
  public func sync(onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
    try await runStreaming(action: "sync", arguments: "", onOutput: onOutput)
  }

  /// Runs `action` on one exact installed version, `name @version_revision+variants`.
  private func runStreaming(
    action: String, port: InstalledPort,
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    try await runStreaming(
      action: action, arguments: try PortClient.versionArguments([port]), onOutput: onOutput)
  }

  /// `name @version_revision+variants` for each port, validated for the shell.
  static func versionArguments(_ ports: [InstalledPort]) throws -> String {
    try ports.map { port in
      guard PortClient.isValidPortName(port.name) else {
        throw PortClientError.invalidName(port.name)
      }
      guard PortClient.isValidVersionSpec(port.versionSpec) else {
        throw PortClientError.invalidName(port.versionSpec)
      }
      return "\(port.name) \(port.versionSpec)"
    }.joined(separator: " ")
  }

  private func runStreaming(
    action: String, name: String,
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    guard PortClient.isValidPortName(name) else { throw PortClientError.invalidName(name) }
    try await runStreaming(action: action, arguments: name, onOutput: onOutput)
  }

  /// `arguments` must already be validated by the caller; it is interpolated
  /// into a shell command.
  private func runStreaming(
    action: String, arguments: String,
    onOutput: @escaping @MainActor @Sendable (String) -> Void
  ) async throws {
    guard isAvailable else { throw PortClientError.notInstalled(executableURL.path) }
    guard PortClient.isSafePath(executableURL.path) else {
      throw PortClientError.invalidName(executableURL.path)
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ports-app-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("install.log")
    guard
      FileManager.default.createFile(
        atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]),
      PortClient.isSafePath(log.path)
    else {
      throw PortClientError.invalidName(log.path)
    }

    let stopFile = directory.appendingPathComponent("stop")
    let command = PortClient.stoppableCommand(
      "\(executableURL.path) -N \(verbose ? "-v " : "")\(action) \(arguments)",
      log: log.path, stopFile: stopFile.path)
    let stop = CommandStop.current
    stop?.register(stopFile)
    defer { stop?.unregister() }
    let tail = Task.detached { await PortClient.tail(log, onOutput: onOutput) }
    do {
      try await runPrivileged(command)
    } catch {
      tail.cancel()
      await tail.value
      throw error
    }
    tail.cancel()
    await tail.value
  }

  /// A shell command that runs `command` with its output in `log`, in its own
  /// process group, and interrupts that whole group (so compilers `port`
  /// started stop too) once `stopFile` exists; if it is still running five
  /// seconds later, it is terminated. Exits with `command`'s status.
  ///
  /// `set -m` gives the background job its own process group; it also keeps
  /// the job from ignoring SIGINT, as background jobs otherwise do. All parts
  /// must already be validated: this is run by a root shell.
  static func stoppableCommand(_ command: String, log: String, stopFile: String) -> String {
    let signal = { (name: String) in "kill -\(name) -$p 2>/dev/null || kill -\(name) $p" }
    return "set -m; \(command) > \(log) 2>&1 & p=$!; "
      + "(while [ ! -e \(stopFile) ]; do sleep 0.2; done; "
      + "\(signal("INT")); sleep 5; \(signal("TERM"))) >/dev/null 2>&1 & w=$!; "
      + "wait $p; s=$?; kill -$w 2>/dev/null || kill $w 2>/dev/null; exit $s"
  }

  /// Adds a ports source to sources.conf. The edited file is staged in a
  /// private temp directory and copied into place with administrator privileges.
  public func addSource(_ url: String, to confPath: String) async throws {
    guard MacPortsInfo.isValidSourceURL(url) else { throw PortClientError.invalidName(url) }
    try await editSources(confPath) { text in
      guard let updated = MacPortsInfo.addingSource(url, to: text) else {
        throw PortClientError.commandFailed(status: 1, stderr: "\(url) is already a source.")
      }
      return updated
    }
  }

  /// Removes a ports source from sources.conf. The last remaining source
  /// cannot be removed.
  public func removeSource(_ url: String, from confPath: String) async throws {
    guard MacPortsInfo.isValidSourceURL(url) else { throw PortClientError.invalidName(url) }
    try await editSources(confPath) { text in
      guard let updated = MacPortsInfo.removingSource(url, from: text) else {
        throw PortClientError.commandFailed(
          status: 1, stderr: "\(url) is not a source, or it is the only source.")
      }
      return updated
    }
  }

  private func editSources(_ confPath: String, _ transform: (String) throws -> String) async throws
  {
    guard PortClient.isSafePath(confPath) else { throw PortClientError.invalidName(confPath) }
    let current = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
    let updated = try transform(current)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ports-app-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let staged = directory.appendingPathComponent("sources.conf")
    try updated.write(to: staged, atomically: true, encoding: .utf8)
    guard PortClient.isSafePath(staged.path) else { throw PortClientError.invalidName(staged.path) }
    try await runPrivileged("/bin/cp \(staged.path) \(confPath)")
  }

  static func isValidVersionSpec(_ spec: String) -> Bool {
    spec.hasPrefix("@")
      && spec.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@._+-".contains($0)) }
  }

  static func isValidVariantFlag(_ flag: String) -> Bool {
    guard let sign = flag.first, sign == "+" || sign == "-" else { return false }
    return isValidPortName(String(flag.dropFirst()).replacingOccurrences(of: ".", with: "_"))
  }

  static func isValidPortName(_ name: String) -> Bool {
    !name.isEmpty
      && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
      && !name.hasPrefix("-")
  }

  /// Paths are interpolated into a shell command, so only a conservative
  /// character set is allowed.
  static func isSafePath(_ path: String) -> Bool {
    !path.isEmpty
      && path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }
  }

  /// Emits complete lines appended to `file` until cancelled, then flushes
  /// whatever remains.
  private static func tail(
    _ file: URL,
    onOutput: @MainActor @Sendable (String) -> Void
  ) async {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return }
    defer { try? handle.close() }
    var pending = Data()

    func drain(final: Bool) async {
      if let chunk = try? handle.readToEnd(), !chunk.isEmpty { pending.append(chunk) }
      let end: Data.Index?
      if final {
        end = pending.endIndex
      } else {
        end = pending.lastIndex(of: 0x0A).map { pending.index(after: $0) }
      }
      guard let end, end > pending.startIndex else { return }
      let text = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
      pending.removeSubrange(pending.startIndex..<end)
      await onOutput(text)
    }

    while !Task.isCancelled {
      await drain(final: false)
      try? await Task.sleep(for: .milliseconds(150))
    }
    await drain(final: true)
  }

  /// Runs a shell command as root via the macOS administrator authorization prompt.
  /// `command` must only contain trusted, validated components.
  func runPrivileged(_ command: String) async throws {
    let script = "do shell script \"\(command)\" with administrator privileges"
    // Terminating osascript would not stop the root shell it started, so let it finish.
    let result = try await ChildProcess.run(
      URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script],
      terminateOnCancel: false)
    guard result.status == 0 else {
      let message = String(decoding: result.stderr, as: UTF8.self)
      if message.contains("-128") { throw PortClientError.cancelled }
      throw PortClientError.commandFailed(status: result.status, stderr: message)
    }
  }

  /// Runs `port` and returns its output. Cancelling the calling task
  /// terminates the process and throws `CancellationError`.
  func run(_ arguments: [String], mergeStderr: Bool = false) async throws -> String {
    guard isAvailable else { throw PortClientError.notInstalled(executableURL.path) }
    let result = try await ChildProcess.run(
      executableURL, arguments: arguments, mergeStderr: mergeStderr)
    guard result.status == 0 else {
      throw PortClientError.commandFailed(
        status: result.status, stderr: String(decoding: result.stderr, as: UTF8.self))
    }
    return String(decoding: result.stdout, as: UTF8.self)
  }
}
