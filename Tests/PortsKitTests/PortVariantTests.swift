// PortVariantTests.swift - Tests for parsing variants and building variant flags.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Testing

@testable import PortsKit

private let sample = """
  ffmpeg has the variants:
     darwinssl: Enable https support
  [+]gpl2: Enable GPL code, license will be GPL-2+
     gpl3: Enable GPL code, license will be GPL-3+
       * requires gpl2
       * conflicts with a b
     universal: Build for multiple architectures
  """

@Test func parsesVariants() {
  let v = PortVariantParser.parse(sample)
  #expect(v.map(\.name) == ["darwinssl", "gpl2", "gpl3", "universal"])
  #expect(v[1].isDefault)
  #expect(!v[0].isDefault)
  #expect(v[2].requires == ["gpl2"])
  #expect(v[2].conflicts == ["a", "b"])
  #expect(v[0].summary == "Enable https support")
}

@Test func buildsFlags() {
  let v = PortVariantParser.parse(sample)
  #expect(PortVariantParser.flags(selected: ["gpl2"], from: v).isEmpty)
  #expect(PortVariantParser.flags(selected: ["universal"], from: v) == ["-gpl2", "+universal"])
}
