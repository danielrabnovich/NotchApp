import Testing
@testable import NotchApp

/// `docker ps` as the ports list reads it.
@MainActor
struct DockerParsingTests {
    @Test func publishedPortsOncePerHostPort() {
        let ports = DockerMonitor.publishedPorts("0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp, 3000/tcp")
        #expect(ports.map(\.host) == [8080])
        #expect(ports.map(\.container) == [8080])
    }

    @Test func remappedAndLocalOnlyPorts() {
        let ports = DockerMonitor.publishedPorts("127.0.0.1:5433->5432/tcp")
        #expect(ports.map(\.host) == [5433])
        #expect(ports.map(\.container) == [5432])
    }

    @Test func unpublishedAndUDPPortsAreSkipped() {
        #expect(DockerMonitor.publishedPorts("5432/tcp").isEmpty)
        #expect(DockerMonitor.publishedPorts("0.0.0.0:53->53/udp").isEmpty)
        #expect(DockerMonitor.publishedPorts("").isEmpty)
    }

    @Test func rowsParseWithComposeNames() throws {
        let out = """
        55628195212d\tgstinstall-web-1\tgamestable.local/web:0.11.0\tUp About an hour\trunning\tgstinstall\t0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp
        ab12\tbuildx_buildkit_eternal0\tmoby/buildkit\tUp 5 days\trunning\t\t
        cd34\tgamestable-postgres-1\tpostgres:16\tUp 5 days (healthy)\trunning\tgamestable\t127.0.0.1:5432->5432/tcp
        """
        let containers = DockerMonitor.parse(out)
        #expect(containers.count == 3)
        let web = try #require(containers.first)
        #expect(web.shortName == "web")
        #expect(web.project == "gstinstall")
        #expect(web.published.map(\.host) == [8080])
        #expect(containers[1].project == nil)
        #expect(containers[1].shortName == "buildx_buildkit_eternal0")
        #expect(containers[2].healthy == true)
        #expect(containers[2].shortName == "postgres")
    }

    @Test func dockerListenersAreRecognised() {
        #expect(DockerMonitor.isDockerProcess("com.docke"))
        #expect(DockerMonitor.isDockerProcess("com.docker.backend"))
        #expect(!DockerMonitor.isDockerProcess("node"))
    }
}
