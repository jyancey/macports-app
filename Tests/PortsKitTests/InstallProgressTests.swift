import Testing
@testable import PortsKit

struct InstallProgressTests {
    @Test func tracksPortsAndDependencies() {
        var p = InstallProgressParser()
        p.consume("""
        --->  Computing dependencies for foo.
        The following dependencies will be installed: 
         bar
         baz
        --->  Fetching archive for bar
        --->  Building baz
        """ + "\n")
        #expect(p.statuses["foo"] == .working("Preparing"))
        #expect(p.statuses["bar"] == .working("Downloading"))
        #expect(p.statuses["baz"] == .working("Building"))
        p.consume("--->  Installing bar @1.0_0\n--->  Cleaning bar\n--->  Staging baz into destroot\n")
        #expect(p.statuses["bar"] == .done)
        #expect(p.statuses["baz"] == .working("Staging"))
    }

    @Test func holdsPartialLines() {
        var p = InstallProgressParser()
        p.consume("--->  Build")
        #expect(p.statuses.isEmpty)
        p.consume("ing zlib\n")
        #expect(p.statuses["zlib"] == .working("Building"))
    }
}
