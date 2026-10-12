// BinaryArchiveTests.swift - Tests for binary archive parsing and matching.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Testing

@testable import PortsKit

struct BinaryArchiveTests {
  let listing = """
    <a href="zlib-1.3.2_0.darwin_27.arm64.tbz2">x</a>
    <a href="zlib-1.3.2_0.darwin_27.arm64.tbz2.rmd160">x</a>
    <a href="GraphicsMagick-1.3.45_3+q8.darwin_27.arm64.tbz2">x</a>
    <a href="zlib-1.3.2_0.darwin_26.x86_64.tbz2">x</a>
    """

  @Test func parsesArchiveNames() {
    let names = BinaryArchive.parseListing(listing)
    #expect(names.count == 3)
    #expect(names.contains("GraphicsMagick-1.3.45_3+q8.darwin_27.arm64.tbz2"))
  }

  @Test func matchesPlatformVersionAndVariants() {
    let names = BinaryArchive.parseListing(listing)
    func has(_ n: String, _ v: String, _ r: Int, _ vars: [String], _ arch: String = "arm64") -> Bool
    {
      BinaryArchive.hasArchive(
        in: names, name: n, version: v, revision: r,
        variants: vars, platform: "darwin_27", arch: arch)
    }
    #expect(has("zlib", "1.3.2", 0, []))
    #expect(!has("zlib", "1.3.2", 1, []))
    #expect(!has("zlib", "1.3.2", 0, [], "x86_64"))
    #expect(has("GraphicsMagick", "1.3.45", 3, ["q8"]))
    #expect(!has("GraphicsMagick", "1.3.45", 3, []))
  }

  @Test func anyArchiveIgnoresVersionButNotPlatform() {
    let names = BinaryArchive.parseListing(listing)
    #expect(
      BinaryArchive.hasAnyArchive(in: names, name: "zlib", platform: "darwin_27", arch: "arm64"))
    #expect(
      BinaryArchive.hasAnyArchive(
        in: names, name: "GraphicsMagick", platform: "darwin_27", arch: "arm64"))
    #expect(
      !BinaryArchive.hasAnyArchive(in: names, name: "zlib", platform: "darwin_25", arch: "arm64"))
    #expect(
      !BinaryArchive.hasAnyArchive(
        in: names, name: "zlib-extra", platform: "darwin_27", arch: "arm64"))
  }
}
