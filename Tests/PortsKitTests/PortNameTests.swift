import Testing
@testable import PortsKit

struct PortNameTests {
    @Test func acceptsRealPortNames() {
        for name in ["zlib", "p5.34-libwww-perl", "gcc14", "g++", "py312-numpy", "libstdc++"] {
            #expect(PortClient.isValidPortName(name))
        }
    }

    @Test func rejectsShellAndOptionSyntax() {
        for name in ["", "-f", "a b", "a;rm", "a\"b", "$(x)", "a'b", "a\\b"] {
            #expect(!PortClient.isValidPortName(name))
        }
    }
}

@Test func safePathsAreConservative() {
    #expect(PortClient.isSafePath("/var/folders/ab/T/ports-app-1-2/install.log"))
    #expect(!PortClient.isSafePath("/tmp/a b"))
    #expect(!PortClient.isSafePath("/tmp/a;rm"))
    #expect(!PortClient.isSafePath(""))
}
