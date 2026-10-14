// AppUpdateModelTests.swift - Tests for checking GitHub for a newer MacPortsApp.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import PortsKit
import Testing

@testable import MacPortsApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppUpdateModelTests {
  /// What the fake GitHub answers, and how often it was asked.
  final class Server: @unchecked Sendable {
    var body = Data("[]".utf8)
    var failure: Error?
    var requests: [URL] = []
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
  }

  struct Offline: LocalizedError {
    var errorDescription: String? { "The Internet connection appears to be offline." }
  }

  let server = Server()
  let defaults = UserDefaults(suiteName: "AppUpdateModelTests-\(UUID().uuidString)")!

  func json(_ releases: [(tag: String, pre: Bool)]) -> Data {
    let items = releases.map {
      #"{"tag_name": "\#($0.tag)", "html_url": "https://github.com/jyancey/macports-app/releases/tag/\#($0.tag)", "prerelease": \#($0.pre)}"#
    }
    return Data("[\(items.joined(separator: ","))]".utf8)
  }

  func makeModel(current: String = "0.4.2") -> AppUpdateModel {
    let server = server
    return AppUpdateModel(
      currentVersion: AppVersion(current)!, defaults: defaults,
      fetch: { url in
        server.requests.append(url)
        if let failure = server.failure { throw failure }
        return server.body
      },
      now: { server.clock })
  }

  @Test func findsANewerRelease() async {
    server.body = json([("0.4.2", false), ("0.5.0", false)])
    let model = makeModel()
    #expect(model.offered == nil)
    let outcome = await model.check()
    #expect(outcome == .updateAvailable(model.latest!))
    #expect(model.offered?.tag == "0.5.0")
    #expect(server.requests == [AppReleases.listURL])
  }

  @Test func upToDateOffersNothing() async {
    server.body = json([("0.4.2", false), ("0.4.1", false)])
    let model = makeModel()
    #expect(await model.check() == .upToDate)
    #expect(model.offered == nil)
    #expect(model.outcome == .upToDate)
  }

  @Test func prereleasesFollowTheSetting() async {
    server.body = json([("0.5.0-rc.1", true)])
    let model = makeModel()
    #expect(await model.check() == .upToDate)
    defaults.set(true, forKey: AppUpdateModel.prereleasesKey)
    _ = await model.check()
    #expect(model.offered?.tag == "0.5.0-rc.1")
  }

  @Test func aFailedCheckIsReportedAndKeepsTheLastAnswer() async {
    server.body = json([("0.5.0", false)])
    let model = makeModel()
    await model.check()
    server.failure = Offline()
    #expect(await model.check() == .failed("The Internet connection appears to be offline."))
    #expect(model.offered?.tag == "0.5.0")
  }

  @Test func unreadableAnswersFail() async {
    server.body = Data(#"{"message": "API rate limit exceeded"}"#.utf8)
    let model = makeModel()
    guard case .failed(let message) = await model.check() else {
      Issue.record("expected a failure")
      return
    }
    #expect(message.contains("couldn't be read"))
    #expect(defaults.object(forKey: AppUpdateModel.lastCheckKey) == nil)
  }

  @Test func skippingHidesThatVersionUntilAnotherComesOut() async {
    server.body = json([("0.5.0", false)])
    let model = makeModel()
    await model.check()
    model.skip(model.latest!)
    #expect(model.offered == nil)
    #expect(makeModel().skippedTag == "0.5.0")

    server.body = json([("0.5.0", false), ("0.5.1", false)])
    await model.check()
    #expect(model.offered?.tag == "0.5.1")

    model.clearSkipped()
    #expect(model.skippedTag == nil)
    #expect(makeModel().skippedTag == nil)
  }

  @Test func automaticChecksRunAtMostOncePerDay() async {
    let model = makeModel()
    await model.checkIfDue()
    await model.checkIfDue()
    #expect(server.requests.count == 1)

    server.clock += AppUpdateModel.checkInterval - 60
    await model.checkIfDue()
    #expect(server.requests.count == 1)
    server.clock += 120
    await model.checkIfDue()
    #expect(server.requests.count == 2)
  }

  @Test func theLastCheckIsRememberedAcrossLaunches() async {
    await makeModel().checkIfDue()
    await makeModel().checkIfDue()
    #expect(server.requests.count == 1)
  }

  @Test func automaticChecksCanBeTurnedOffButManualOnesStillWork() async {
    defaults.set(false, forKey: AppUpdateModel.autoCheckKey)
    let model = makeModel()
    await model.checkIfDue()
    #expect(server.requests.isEmpty)
    await model.check()
    #expect(server.requests.count == 1)
  }

  @Test func aFailedAutomaticCheckIsTriedAgainNextTime() async {
    server.failure = Offline()
    let model = makeModel()
    await model.checkIfDue()
    server.failure = nil
    await model.checkIfDue()
    #expect(server.requests.count == 2)
  }
}
