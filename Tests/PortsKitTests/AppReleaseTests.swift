// AppReleaseTests.swift - Tests for version ordering and choosing the newest GitHub release.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Testing

@testable import PortsKit

@Suite struct AppVersionTests {
  func v(_ text: String) -> AppVersion { AppVersion(text)! }

  @Test func parsesTagsWithAndWithoutV() {
    #expect(v("0.4.2").numbers == [0, 4, 2])
    #expect(v("v0.4.2") == v("0.4.2"))
    #expect(v("0.5.0-rc.1").prerelease == ["rc", "1"])
    #expect(v(" 1.2 ").numbers == [1, 2])
  }

  @Test func describesItselfAsATag() {
    #expect(v("v0.4.2").description == "0.4.2")
    #expect(v("0.5.0-rc.1").description == "0.5.0-rc.1")
  }

  @Test func rejectsWhatIsNotAVersion() {
    for text in ["", "latest", "1..2", "1.x", "v", "1.0-", "1.0-rc..1", "release-1"] {
      #expect(AppVersion(text) == nil, "\(text)")
    }
  }

  @Test func ordersNumbersNumerically() {
    #expect(v("0.4.2") < v("0.4.10"))
    #expect(v("0.9.0") < v("0.10.0"))
    #expect(v("1.0") == v("1.0.0"))
    #expect(Set([v("1.0"), v("1.0.0")]).count == 1)
    #expect(v("0.4.2") < v("1"))
  }

  @Test func aPrereleaseIsOlderThanItsRelease() {
    #expect(v("0.5.0-rc.1") < v("0.5.0"))
    #expect(v("0.4.2") < v("0.5.0-rc.1"))
    #expect(v("0.5.0-rc.1") < v("0.5.0-rc.2"))
    #expect(v("0.5.0-rc.2") < v("0.5.0-rc.10"))
    #expect(v("0.5.0-alpha") < v("0.5.0-beta"))
    #expect(v("0.5.0-rc") < v("0.5.0-rc.1"))
    #expect(v("0.5.0-1") < v("0.5.0-alpha"))
    #expect(v("0.5.0").isPrerelease == false)
    #expect(v("0.5.0-rc.1").isPrerelease)
  }
}

@Suite struct AppReleasesTests {
  func release(
    _ tag: String, prerelease: Bool = false, draft: Bool = false
  ) -> AppRelease {
    AppRelease(
      tag: tag, url: URL(string: "https://github.com/x/y/releases/tag/\(tag)")!,
      isPrerelease: prerelease, isDraft: draft)
  }

  let current = AppVersion("0.4.2")!

  @Test func parsesTheGitHubResponse() throws {
    let json = """
      [{"tag_name": "0.5.0", "html_url": "https://github.com/jyancey/macports-app/releases/tag/0.5.0",
        "prerelease": false, "draft": false, "body": "Notes", "id": 1, "assets": []},
       {"tag_name": "0.5.0-rc.1", "html_url": "https://github.com/jyancey/macports-app/releases/tag/0.5.0-rc.1",
        "prerelease": true, "body": null}]
      """
    let releases = try AppReleases.parse(Data(json.utf8))
    #expect(releases.map(\.tag) == ["0.5.0", "0.5.0-rc.1"])
    #expect(releases[0].notes == "Notes")
    #expect(releases[1].isPrerelease && !releases[1].isDraft && releases[1].notes == "")
  }

  @Test func unreadableResponsesThrow() {
    #expect(throws: AppReleases.ParseError.self) { try AppReleases.parse(Data("nope".utf8)) }
    // GitHub's rate-limit and error replies are objects, not lists.
    #expect(throws: AppReleases.ParseError.self) {
      try AppReleases.parse(Data(#"{"message": "API rate limit exceeded"}"#.utf8))
    }
  }

  @Test func picksTheNewestStableRelease() {
    let list = [
      release("0.4.2"), release("0.5.0"), release("0.4.10"), release("0.5.1-rc.1", prerelease: true),
    ]
    #expect(
      AppReleases.newest(in: list, after: current, includePrereleases: false)?.tag == "0.5.0")
  }

  @Test func prereleasesCountOnlyWhenAsked() {
    let list = [release("0.5.0"), release("0.6.0-rc.1", prerelease: true)]
    #expect(
      AppReleases.newest(in: list, after: current, includePrereleases: true)?.tag == "0.6.0-rc.1")
    #expect(
      AppReleases.newest(in: list, after: current, includePrereleases: false)?.tag == "0.5.0")
    // A tag with a pre-release suffix is one even if GitHub's flag isn't set.
    let unflagged = [release("0.6.0-rc.1")]
    #expect(AppReleases.newest(in: unflagged, after: current, includePrereleases: false) == nil)
  }

  @Test func nothingNewerMeansNoUpdate() {
    let list = [release("0.4.2"), release("0.4.1"), release("0.3.0")]
    #expect(AppReleases.newest(in: list, after: current, includePrereleases: true) == nil)
    #expect(AppReleases.newest(in: [], after: current, includePrereleases: true) == nil)
  }

  @Test func draftsAndOddTagsAreIgnored() {
    let list = [release("0.9.0", draft: true), release("nightly"), release("0.4.3")]
    #expect(
      AppReleases.newest(in: list, after: current, includePrereleases: true)?.tag == "0.4.3")
  }

  @Test func aPrereleaseUserIsOfferedTheFinalRelease() {
    let rc = AppVersion("0.5.0-rc.1")!
    let list = [release("0.5.0"), release("0.5.0-rc.1", prerelease: true)]
    #expect(AppReleases.newest(in: list, after: rc, includePrereleases: false)?.tag == "0.5.0")
  }
}
