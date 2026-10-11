import Foundation
import Testing

@testable import PortsKit

/// A MacPorts prefix in a temp directory: `bin/port` logs each call, and
/// `etc/macports` holds the config files.
struct FakePrefix {
  let root: URL
  let client: PortClient

  init(
    conf: String,
    sources: String =
      "rsync://rsync.macports.org/macports/release/tarballs/ports.tar.gz [default]\n"
  ) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ports-app-prefix-\(UUID().uuidString)", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(
      at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try fm.createDirectory(
      at: root.appendingPathComponent("etc/macports"), withIntermediateDirectories: true)
    let port = root.appendingPathComponent("bin/port")
    try """
    #!/bin/sh
    echo "$@" >> "$(dirname "$0")/../calls"
    echo "Version: 2.12.6"
    """.write(to: port, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: port.path)
    try conf.write(
      to: root.appendingPathComponent("etc/macports/macports.conf"), atomically: true,
      encoding: .utf8)
    try sources.write(
      to: root.appendingPathComponent("etc/macports/sources.conf"), atomically: true,
      encoding: .utf8)
    client = PortClient(executablePath: port.path, verbose: false)
  }

  var path: String { root.path }

  /// Arguments of each `port` call, one per line.
  var calls: [String] {
    ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
      .split(separator: "\n").map(String.init)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct MacPortsConfigTests {
  @Test func infoRunsPortOnlyForTheVersion() async throws {
    let prefix = try FakePrefix(conf: "# comment\napplications_dir /Applications/Ports\n")
    defer { prefix.remove() }
    let info = try await prefix.client.macPortsInfo()
    #expect(info.version == "2.12.6")
    #expect(info.prefix == prefix.path)
    #expect(info.dataPath == prefix.path + "/var/macports")
    #expect(info.applicationsDir == "/Applications/Ports")
    #expect(info.sourcesConfPath == prefix.path + "/etc/macports/sources.conf")
    #expect(info.sources == ["rsync://rsync.macports.org/macports/release/tarballs/ports.tar.gz"])
    #expect(prefix.calls == ["version"])
  }

  @Test func dataPathComesFromTheConfigWithoutRunningPort() throws {
    let prefix = try FakePrefix(conf: "portdbpath /custom/db\n")
    defer { prefix.remove() }
    #expect(prefix.client.dataPath() == "/custom/db")
    #expect(prefix.calls.isEmpty)
  }

  @Test func dataPathDefaultsUnderThePrefix() throws {
    let prefix = try FakePrefix(conf: "")
    defer { prefix.remove() }
    #expect(prefix.client.dataPath() == prefix.path + "/var/macports")
  }

  @Test func registryCheckDoesNotRunPort() async throws {
    let prefix = try FakePrefix(conf: "")
    defer { prefix.remove() }
    let status = await prefix.client.registryStatus()
    #expect(status.path == prefix.path + "/var/macports/registry/registry.db")
    #expect(!status.exists)
    #expect(prefix.calls.isEmpty)
  }

  @Test func sourcePathsFollowMacPortsLayout() {
    let db = "/opt/local/var/macports"
    #expect(
      MacPortsInfo.sourcePath(
        for: "rsync://rsync.macports.org/macports/release/tarballs/ports.tar.gz", dataPath: db)
        == db + "/sources/rsync.macports.org/macports/release/tarballs/ports")
    #expect(
      MacPortsInfo.sourcePath(
        for: "https://packages.example.org/macports/ports.tar.bz2", dataPath: db)
        == db + "/sources/packages.example.org/macports/ports")
    #expect(
      MacPortsInfo.sourcePath(
        for: "rsync://rsync.example.org/macports/release/ports/", dataPath: db)
        == db + "/sources/rsync.example.org/macports/release/ports")
    #expect(
      MacPortsInfo.sourcePath(for: "file:///Users/me/ports", dataPath: db) == "/Users/me/ports")
  }

  @Test func lastSyncIsTheNewestPortIndex() async throws {
    let prefix = try FakePrefix(
      conf: "",
      sources:
        "file:///nonexistent/ports\nrsync://rsync.macports.org/macports/release/tarballs/ports.tar.gz [default]\n"
    )
    defer { prefix.remove() }
    let tree =
      prefix.path + "/var/macports/sources/rsync.macports.org/macports/release/tarballs/ports"
    try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
    let synced = Date(timeIntervalSince1970: 1_790_000_000)
    FileManager.default.createFile(
      atPath: tree + "/PortIndex", contents: Data(), attributes: [.modificationDate: synced])
    #expect(try await prefix.client.macPortsInfo().lastSync == synced)
  }

  @Test func lastSyncIsUnknownWithoutAPortIndex() async throws {
    let prefix = try FakePrefix(conf: "")
    defer { prefix.remove() }
    #expect(try await prefix.client.macPortsInfo().lastSync == nil)
  }

  /// The bug this fixes: the real install always showed "Last sync: Unknown".
  @Test func realInstallHasALastSync() async throws {
    let client = PortClient()
    guard client.isAvailable else { return }
    #expect(try await client.macPortsInfo().lastSync != nil)
  }
}
