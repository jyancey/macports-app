import Foundation
import Testing
@testable import PortsKit

@Suite struct PortInfoParserTests {
    private let zlibLine = "zlib\t1.3.2\t0\tarchivers\tA compression library.\thttps://www.zlib.net/\tzlib\t"
        + "ryandesign@macports.org ryandesign,openmaintainer\tuniversal\t\t\t\tdarwin,freebsd\tminizip\n"

    @Test func parsesInfoLine() throws {
        let info = try #require(PortInfoParser.parse(zlibLine))
        #expect(info.name == "zlib")
        #expect(info.version == "1.3.2")
        #expect(info.categories == ["archivers"])
        #expect(info.homepage == URL(string: "https://www.zlib.net/"))
        #expect(info.variants == ["universal"])
        #expect(info.libDependencies.isEmpty)
        #expect(info.platforms == ["darwin", "freebsd"])
        #expect(info.subports == ["minizip"])
    }

    @Test func parsesDependencies() throws {
        let line = "p\t1\t0\tc\td\t\tl\tm\t\ta,b\tc\t\t\t\n"
        let info = try #require(PortInfoParser.parse(line))
        #expect(info.libDependencies == ["a", "b"])
        #expect(info.buildDependencies == ["c"])
        #expect(info.homepage == nil)
    }

    @Test func rejectsGarbage() {
        #expect(PortInfoParser.parse("Error: Port x not found") == nil)
        #expect(PortInfoParser.parse("") == nil)
    }

    @Test func parsesFilesAndDependents() {
        #expect(PortInfoParser.parseFileList("  /opt/local/a\n  /opt/local/b\n") == ["/opt/local/a", "/opt/local/b"])
        #expect(PortInfoParser.parseDependents("clang-23\ngcc15\n") == ["clang-23", "gcc15"])
        #expect(PortInfoParser.parseDependents("foo has no dependents!\n").isEmpty)
    }
}
