import Testing
@testable import PortsKit

@Suite struct MacPortsInfoTests {
    @Test func parsesVersion() {
        #expect(MacPortsInfo.parseVersion("Version: 2.12.6\n") == "2.12.6")
    }

    @Test func parsesConfIgnoringComments() {
        let c = MacPortsInfo.parseConf("# x\nprefix \t/opt/local\n\nportdbpath /opt/local/var/macports\n")
        #expect(c["prefix"] == "/opt/local")
        #expect(c["portdbpath"] == "/opt/local/var/macports")
        #expect(c.count == 2)
    }

    @Test func parsesSources() {
        let s = MacPortsInfo.parseSources("# c\nfile:///a\nrsync://h/p [default]\n")
        #expect(s == ["file:///a", "rsync://h/p"])
    }
}

@Suite struct ExecutablePathTests {
    @Test func rejectsUnsafeAndMissingPaths() {
        #expect(PortClient.problem(withExecutablePath: "/opt/local/bin/port; rm -rf ~") != nil)
        #expect(PortClient.problem(withExecutablePath: "relative/port") != nil)
        #expect(PortClient.problem(withExecutablePath: "/nonexistent/port") != nil)
        #expect(PortClient.problem(withExecutablePath: "/opt/local/bin") != nil)
    }

    @Test func acceptsAnExecutable() {
        #expect(PortClient.problem(withExecutablePath: "/bin/ls") == nil)
    }
}
