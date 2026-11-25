import AppKit

/// Docker's running containers, for the ports list: which container is behind a port Docker
/// listens on, and a way to stop or restart one (not Docker itself). Read with the docker command
/// when the list opens; nothing runs in the background.
@MainActor
final class DockerMonitor: ObservableObject {
    static let shared = DockerMonitor()

    struct Container: Identifiable, Equatable {
        let id: String
        let name: String
        let image: String
        /// "Up 5 days (healthy)".
        let status: String
        let running: Bool
        /// The compose project it belongs to, if any.
        let project: String?
        /// Ports published on this Mac: host port → the container's.
        let published: [(host: Int, container: Int)]

        static func == (a: Container, b: Container) -> Bool {
            a.id == b.id && a.status == b.status && a.running == b.running && a.published.map(\.host) == b.published.map(\.host)
        }

        var healthy: Bool? {
            status.contains("(healthy)") ? true : status.contains("(unhealthy)") ? false : nil
        }
        /// The name without its compose project prefix and replica number ("web" for "shop-web-1").
        var shortName: String {
            guard let project, name.hasPrefix(project + "-") else { return name }
            var rest = name.dropFirst(project.count + 1)
            if let dash = rest.lastIndex(of: "-"), Int(rest[rest.index(after: dash)...]) != nil { rest = rest[..<dash] }
            return String(rest)
        }
    }

    @Published private(set) var containers: [Container] = []
    @Published private(set) var busy: Set<String> = []

    /// The docker command: Homebrew's, else the one inside Docker Desktop (or OrbStack).
    nonisolated static let cli: String? = [
        "/opt/homebrew/bin/docker", "/usr/local/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orbstack/bin/docker").path,
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Docker's own processes, which listen on behalf of containers.
    static func isDockerProcess(_ command: String) -> Bool {
        let c = command.lowercased()
        return c.hasPrefix("com.docke") || c.contains("vpnkit") || c == "orbstack" || c.hasPrefix("orbstack")
    }

    func refresh() {
        guard let cli = Self.cli else { return }
        Task.detached(priority: .utility) {
            let format = #"{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.State}}\t{{.Label "com.docker.compose.project"}}\t{{.Ports}}"#
            let result = Shell.runSync(cli, ["ps", "--format", format], timeout: 8)
            // Docker not running: no containers, rather than an error.
            let found = result.ok ? Self.parse(result.out) : []
            await MainActor.run {
                let docker = DockerMonitor.shared
                if docker.containers != found { docker.containers = found }
            }
        }
    }

    /// The running container that publishes this port on the Mac.
    func container(publishing port: Int) -> Container? {
        containers.first { $0.published.contains { $0.host == port } }
    }

    func stop(_ c: Container) { run(["stop", c.id], on: c) }

    /// From Search ("stop port 8080"): asks Docker which container publishes it, then stops that one.
    func stopContainer(publishing port: Int) {
        guard let cli = Self.cli else { return }
        Task {
            let found = await Shell.run(cli, ["ps", "--filter", "publish=\(port)", "--format", "{{.ID}}\t{{.Names}}"], timeout: 8)
            let row = found.out.split(separator: "\n").first.map { $0.split(separator: "\t").map(String.init) }
            guard let row, row.count == 2 else {
                ActivityCenter.shared.show(.notice(title: "No container on port \(port)", detail: "Docker is listening, but nothing it runs publishes that port",
                                                   icon: "shippingbox", tone: .warning), for: 3)
                return
            }
            let stopped = await Shell.run(cli, ["stop", row[0]], timeout: 60)
            ActivityCenter.shared.show(.notice(title: stopped.ok ? "Stopped \(row[1])" : "Docker couldn't stop \(row[1])", detail: "Port \(port)",
                                               icon: "shippingbox", tone: stopped.ok ? .success : .warning), for: 3)
            refresh()
            PortScanner.shared.refresh()
        }
    }
    func restart(_ c: Container) { run(["restart", c.id], on: c) }

    private func run(_ args: [String], on c: Container) {
        guard let cli = Self.cli, !busy.contains(c.id) else { return }
        busy.insert(c.id)
        Task {
            let result = await Shell.run(cli, args, timeout: 60)
            busy.remove(c.id)
            if !result.ok {
                ActivityCenter.shared.show(.notice(title: "Docker couldn't \(args[0]) \(c.shortName)", detail: c.image,
                                                   icon: "shippingbox", tone: .warning), for: 3)
            }
            refresh()
            PortScanner.shared.refresh()
        }
    }

    // MARK: - Parsing

    /// `docker ps` rows, tab-separated in the order of the format above.
    nonisolated static func parse(_ output: String) -> [Container] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { return nil }
            return Container(id: f[0], name: f[1], image: f[2], status: f[3], running: f[4] == "running",
                             project: f[5].isEmpty ? nil : f[5], published: publishedPorts(f[6]))
        }
    }

    /// "0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp, 3000/tcp" → [(8080, 8080)]: each host port once,
    /// TCP only, and only the ones published (a bare "3000/tcp" is the container's alone).
    nonisolated static func publishedPorts(_ text: String) -> [(host: Int, container: Int)] {
        var seen = Set<Int>()
        var out: [(Int, Int)] = []
        for part in text.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard p.hasSuffix("/tcp"), let arrow = p.range(of: "->") else { continue }
            let hostSide = p[..<arrow.lowerBound], containerSide = p[arrow.upperBound...].dropLast(4)
            guard let colon = hostSide.lastIndex(of: ":"),
                  let host = Int(hostSide[hostSide.index(after: colon)...]),
                  let inside = Int(containerSide.split(separator: "-").first ?? "") else { continue }
            if seen.insert(host).inserted { out.append((host, inside)) }
        }
        return out
    }
}
