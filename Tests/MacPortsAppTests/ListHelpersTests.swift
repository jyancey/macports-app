// ListHelpersTests.swift - Tests for the port list helpers and load error handling.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import PortsKit
import Testing

@testable import MacPortsApp

final class Box: @unchecked Sendable { var fail = false }

@MainActor
@Suite struct ListHelpersTests {
  func port(_ name: String, active: Bool = true) -> InstalledPort {
    InstalledPort(name: name, version: "1.0", revision: 0, variants: [], isActive: active)
  }

  @Test func installedNamesFollowThePorts() {
    let model = InstalledPortsModel()
    model.ports = [port("zlib"), port("zlib", active: false), port("git")]
    #expect(model.names == ["zlib", "git"])
    model.ports = [port("bash")]
    #expect(model.names == ["bash"])
  }

  @Test func sizesFillInAfterThePortsLoad() async throws {
    let ports = [port("zlib"), port("git"), port("empty")]
    let model = InstalledPortsModel(
      fetch: { ports }, fetchUsage: { ["zlib@1.0_0": 2048, "git@1.0_0": 10] })
    await model.load()
    #expect(try await until { model.ports.allSatisfy { $0.diskUsage != nil } })
    #expect(model.ports.map(\.diskUsage) == [2048, 10, 0])
    #expect(!model.isLoading)
  }

  @Test func portsShowWithoutSizesWhenTheyCantBeMeasured() async throws {
    let model = InstalledPortsModel(fetch: { [InstalledPort(name: "zlib", version: "1.0", revision: 0, variants: [], isActive: true)] },
      fetchUsage: { nil })
    await model.load()
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.ports.map(\.name) == ["zlib"])
    #expect(model.ports[0].diskUsage == nil)
  }

  @Test func aFailedLoadClearsTheSizes() async throws {
    struct Failure: Error {}
    let box = Box()
    let model = InstalledPortsModel(
      fetch: { if box.fail { throw Failure() } else { [InstalledPort(
        name: "zlib", version: "1.0", revision: 0, variants: [], isActive: true)] } },
      fetchUsage: { ["zlib@1.0_0": 5] })
    await model.load()
    #expect(try await until { model.ports.first?.diskUsage == 5 })
    box.fail = true
    await model.load()
    #expect(model.ports.isEmpty)
    #expect(model.errorMessage != nil)
  }

  @Test func unmeasuredVersionsSortBeforeMeasuredOnes() {
    var measured = port("a")
    measured.diskUsage = 0
    #expect(port("b").sortUsage < measured.sortUsage)
    #expect([measured, port("b")].sorted { $0.sortUsage < $1.sortUsage }.map(\.name) == ["b", "a"])
  }

  @Test func fileSizesUseFinderUnits() {
    #expect(Int64(2_000_000).fileSize == "2 MB")
  }

  @Test func filterMatchesNamesIgnoringCase() {
    let ports = [port("py313-numpy"), port("NumPy-docs"), port("zlib")]
    #expect(ports.matching("").map(\.name) == ["py313-numpy", "NumPy-docs", "zlib"])
    #expect(ports.matching("numpy").map(\.name) == ["py313-numpy", "NumPy-docs"])
    #expect(ports.matching("nothing").isEmpty)
  }
}

@Test func installCommandKeepsTheVariants() {
  let plain = InstalledPort(name: "zlib", version: "1.3", revision: 0, variants: [], isActive: true)
  let withVariants = InstalledPort(
    name: "git", version: "2.45", revision: 0, variants: ["universal", "svn"], isActive: true)
  #expect(plain.installCommand == "sudo port install zlib")
  #expect(withVariants.installCommand == "sudo port install git +universal +svn")
}

@MainActor
@Suite struct LoadErrorTests {
  struct Failure: Error {}

  @Test func missingPortIsRecognised() async {
    let missing = InstalledPortsModel { throw PortClientError.notInstalled("/opt/local/bin/port") }
    await missing.load()
    #expect(missing.isPortMissing)
    #expect(missing.errorMessage != nil)

    let failing = InstalledPortsModel { throw Failure() }
    await failing.load()
    #expect(!failing.isPortMissing)
    #expect(failing.errorMessage != nil)
  }

  @Test func successfulLoadClearsTheMissingFlag() async {
    final class Attempts: @unchecked Sendable { var count = 0 }
    let attempts = Attempts()
    let model = InstalledPortsModel {
      attempts.count += 1
      if attempts.count == 1 { throw PortClientError.notInstalled("/opt/local/bin/port") }
      return []
    }
    await model.load()
    #expect(model.isPortMissing)
    await model.load()
    #expect(!model.isPortMissing)
    #expect(model.errorMessage == nil)
  }

  @Test func retryRunsTheLastSearchAgain() async throws {
    final class Calls: @unchecked Sendable { var list: [String] = [] }
    let calls = Calls()
    let model = SearchModel(
      search: { term, scope in
        calls.list.append("\(term) \(scope.rawValue)")
        throw Failure()
      },
      binaryHint: { _ in .unknown })
    model.retry()  // nothing searched yet: nothing to retry
    model.search("zlib", scope: .exact)
    #expect(try await until { model.errorMessage != nil })
    model.retry()
    #expect(try await until { calls.list.count == 2 })
    #expect(calls.list == ["zlib Exact", "zlib Exact"])
  }
}

@Test func countsUseTheRightNumber() {
  #expect(counted(0, "result") == "0 results")
  #expect(counted(1, "result") == "1 result")
  #expect(counted(2, "group") == "2 groups")
  #expect(counted(3, "match", plural: "matches") == "3 matches")
}
