import PortsKit
import Testing

@testable import MacPortsApp

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
