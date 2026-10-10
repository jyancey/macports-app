import Testing

@testable import PortsKit

@Suite struct DiagnoseParserTests {
  @Test func parsesWarningsAndContinuations() {
    let out = """
      Warning: found dylibs in your /usr/local/lib directory. These are known to cause problems.
      Error: something broke
      and continues here
      """
    let findings = DiagnoseParser.parse(out)
    #expect(findings.count == 2)
    #expect(findings[0].severity == .warning)
    #expect(findings[1].severity == .error)
    #expect(findings[1].message == "something broke\nand continues here")
  }

  @Test func emptyOutputMeansNoFindings() {
    #expect(DiagnoseParser.parse("").isEmpty)
    #expect(DiagnoseParser.parse("--->  Checking things\n").isEmpty)
  }
}
