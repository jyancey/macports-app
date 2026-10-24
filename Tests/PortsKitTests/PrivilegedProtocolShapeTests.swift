// PrivilegedProtocolShapeTests.swift - Fails when what crosses the helper connection changes without a protocol bump.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation
import ObjectiveC
import Testing

@testable import PortsKit

/// After an update, the new app can briefly talk to the old helper, which is
/// still running. `HelperConstants.protocolVersion` is what tells them apart,
/// so the app falls back to the password prompt instead of sending requests
/// the helper misreads. This pins everything that crosses the connection to
/// the version, so a change without a bump fails here.
@Suite struct PrivilegedProtocolShapeTests {
  /// The shape of each protocol version. When you change a request, reply or
  /// XPC method: bump `HelperConstants.protocolVersion`, then add the new
  /// shape here (the failure message prints it). Keep the old ones.
  static let pinned: [Int: String] = [
    1: """
      PrivilegedCommand { arguments: [string], portPath: string, protocolVersion: number, verb: string, verbose: bool }
      SourcesUpdate { contents: string, portPath: string, protocolVersion: number }
      PrivilegedResult { kind: string, message: string, status: number }
      PrivilegedResult.Kind: cancelled, finished, rejected, versionMismatch
      PrivilegedHelperProtocol: cancel:, protocolVersionWithReply:, run:command:output:reply:, writeSources:reply:
      PrivilegedOutputProtocol: receive:
      """
  ]

  @Test func theShapeMatchesTheProtocolVersion() throws {
    let version = HelperConstants.protocolVersion
    let actual = try Self.currentShape()
    guard let expected = Self.pinned[version] else {
      Issue.record(
        """
        Protocol version \(version) has no pinned shape. Add it to \
        PrivilegedProtocolShapeTests.pinned:

        \(actual)
        """)
      return
    }
    #expect(
      actual == expected,
      """
      What crosses the helper connection changed, but HelperConstants.protocolVersion \
      is still \(version). Bump it, so a new app doesn't talk to an old helper, then pin \
      the new shape in PrivilegedProtocolShapeTests.pinned:

      \(actual)
      """)
  }

  @Test func olderVersionsKeepTheirShapes() {
    // Every version up to the current one stays pinned, so a bump can't
    // quietly reuse an old number.
    for version in 1...HelperConstants.protocolVersion {
      #expect(Self.pinned[version] != nil, "protocol version \(version) isn't pinned")
    }
  }

  // MARK: - Describing the shape

  static func currentShape() throws -> String {
    // Every collection non-empty, so its element type shows.
    let command = PrivilegedCommand(
      verb: "install", arguments: ["zlib"], verbose: true, portPath: "/opt/local/bin/port")
    let update = SourcesUpdate(contents: "rsync://example/", portPath: "/opt/local/bin/port")
    let result = PrivilegedResult(kind: .finished, status: 1, message: "done")
    return [
      try describe("PrivilegedCommand", command),
      try describe("SourcesUpdate", update),
      try describe("PrivilegedResult", result),
      "PrivilegedResult.Kind: "
        + PrivilegedResult.Kind.allCases.map(\.rawValue).sorted().joined(separator: ", "),
      "PrivilegedHelperProtocol: "
        + selectors(of: PrivilegedHelperProtocol.self).joined(separator: ", "),
      "PrivilegedOutputProtocol: "
        + selectors(of: PrivilegedOutputProtocol.self).joined(separator: ", "),
    ].joined(separator: "\n")
  }

  /// "Name { field: type, … }" from the value's JSON encoding.
  static func describe(_ name: String, _ value: some Encodable) throws -> String {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    let fields = try #require(object as? [String: Any])
    let described = fields.keys.sorted().map { "\($0): \(type(of: fields[$0]!))" }
    return "\(name) { \(described.joined(separator: ", ")) }"
  }

  static func type(of json: Any) -> String {
    switch json {
    case let array as [Any]: "[\(array.first.map(type(of:)) ?? "empty")]"
    case is [String: Any]: "object"
    case is String: "string"
    // JSONSerialization gives booleans as NSNumber too; tell them apart by their type.
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): "bool"
    case is NSNumber: "number"
    case is NSNull: "null"
    default: "\(Swift.type(of: json))"
    }
  }

  /// The required instance methods of an `@objc` protocol, sorted.
  static func selectors(of proto: Protocol) -> [String] {
    var count: UInt32 = 0
    guard let list = protocol_copyMethodDescriptionList(proto, true, true, &count) else {
      return []
    }
    defer { free(list) }
    return (0..<Int(count)).compactMap { list[$0].name.map(NSStringFromSelector) }.sorted()
  }
}
