// AppResources.swift - Finds the app's bundled resources without SwiftPM's crashing Bundle.module accessor.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation

/// Locates files in the SwiftPM resource bundle.
///
/// `Bundle.module` looks for the bundle at the root of the `.app` or at the
/// absolute path it was built at, and stops the app with a fatal error when
/// neither exists. The packaged app keeps the bundle in `Contents/Resources`
/// (where code signing allows it), so a build from another machine, such as
/// a downloaded release, crashed at launch. This looks where the bundle really
/// is and returns nil when it isn't there.
enum AppResources {
  /// The bundle SwiftPM makes for the app target: `<package>_<target>.bundle`.
  static let bundleName = "MacPortsApp_MacPortsApp.bundle"

  /// The file `name.ext` in the resource bundle, or nil. `resourceURL` is
  /// `Contents/Resources` in the packaged app and the build folder in
  /// `swift run`.
  static func url(
    forResource name: String, withExtension ext: String,
    resourceURL: URL? = Bundle.main.resourceURL
  ) -> URL? {
    guard let resourceURL,
      let bundle = Bundle(url: resourceURL.appendingPathComponent(bundleName))
    else { return nil }
    return bundle.url(forResource: name, withExtension: ext)
  }
}
