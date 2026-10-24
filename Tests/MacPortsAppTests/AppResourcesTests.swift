// AppResourcesTests.swift - Tests for finding bundled resources in the packaged app's layout.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import Testing

@testable import MacPortsApp

@Suite struct AppResourcesTests {
  /// A `Contents/Resources` folder, with the SwiftPM bundle when `withBundle`.
  func makeResources(withBundle: Bool, file: String = "AppIcon.png") throws -> URL {
    let resources = FileManager.default.temporaryDirectory
      .appendingPathComponent("resources-test-\(UUID().uuidString)/Contents/Resources")
    let bundle = resources.appendingPathComponent(AppResources.bundleName)
    try FileManager.default.createDirectory(
      at: withBundle ? bundle : resources, withIntermediateDirectories: true)
    if withBundle {
      try Data("png".utf8).write(to: bundle.appendingPathComponent(file))
    }
    return resources
  }

  @Test func findsAFileInTheBundleInsideContentsResources() throws {
    let resources = try makeResources(withBundle: true)
    defer { try? FileManager.default.removeItem(at: resources) }
    let url = AppResources.url(forResource: "AppIcon", withExtension: "png", resourceURL: resources)
    #expect(url?.lastPathComponent == "AppIcon.png")
    #expect(url?.path.contains(AppResources.bundleName) == true)
  }

  /// What a downloaded release used to do: crash. It should return nil instead.
  @Test func aMissingBundleOrFileIsNilNotACrash() throws {
    let empty = try makeResources(withBundle: false)
    defer { try? FileManager.default.removeItem(at: empty) }
    #expect(AppResources.url(forResource: "AppIcon", withExtension: "png", resourceURL: empty) == nil)
    #expect(AppResources.url(forResource: "AppIcon", withExtension: "png", resourceURL: nil) == nil)

    let other = try makeResources(withBundle: true, file: "Other.png")
    defer { try? FileManager.default.removeItem(at: other) }
    #expect(AppResources.url(forResource: "AppIcon", withExtension: "png", resourceURL: other) == nil)
  }

  @Test func theRealBundleNameMatchesWhatSwiftPMBuilds() throws {
    // package.sh copies the built `*.bundle`; the name must be the one looked up.
    let built = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build")
    let found = FileManager.default.enumerator(at: built, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .contains { $0.lastPathComponent == AppResources.bundleName }
    // Only meaningful where the package has been built; skipped on a clean checkout.
    if let found { #expect(found) }
  }
}
