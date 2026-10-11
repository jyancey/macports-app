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
