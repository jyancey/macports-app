import Testing

@testable import PortsKit

@Suite struct PortListParserTests {
  @Test func parsesActivePortWithVariants() {
    let ports = PortListParser.parseInstalled("  clang-23 @23.1.3_0+analyzer (active)\n")
    #expect(
      ports == [
        InstalledPort(
          name: "clang-23", version: "23.1.3", revision: 0,
          variants: ["analyzer"], isActive: true)
      ])
  }

  @Test func parsesInactivePortWithoutVariants() {
    let ports = PortListParser.parseInstalled("  db48 @4.8.30_5\n")
    #expect(ports.first?.isActive == false)
    #expect(ports.first?.revision == 5)
    #expect(ports.first?.variants == [])
  }

  @Test func parsesMultipleVariants() {
    let port = PortListParser.parseLine("  gcc15 @15.2.0_0+stdlib_flag+clang18 (active)")
    #expect(port?.version == "15.2.0")
    #expect(port?.variants == ["stdlib_flag", "clang18"])
  }

  @Test func identifiesEachInstalledVersion() {
    let ports = PortListParser.parseInstalled(
      "  gcc15 @15.2.0_0+stdlib_flag+clang18 (active)\n  gcc15 @15.1.0_1\n  db48 @4.8.30_5\n")
    #expect(
      ports.map(\.id) == ["gcc15@15.2.0_0+stdlib_flag+clang18", "gcc15@15.1.0_1", "db48@4.8.30_5"])
  }

  @Test func ignoresHeadersAndBlankLines() {
    let out = "The following ports are currently installed:\n\n  a @1_0 (active)\n"
    #expect(PortListParser.parseInstalled(out).map(\.name) == ["a"])
  }
}
