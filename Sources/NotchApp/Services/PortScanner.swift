import AppKit

/// What's listening on which TCP port (from `lsof`), with a way to stop it.
@MainActor
final class PortScanner: ObservableObject {
    static let shared = PortScanner()

    struct Listener: Identifiable, Hashable {
        var id: String { "\(pid):\(port)" }
        let port: Int
        let pid: pid_t
        let command: String
        /// "*" for every interface, "127.0.0.1" for this Mac only.
        let address: String
        var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
        var isLocalOnly: Bool { address.hasPrefix("127.") || address == "[::1]" || address == "localhost" }
        var displayName: String { app?.localizedName ?? command }
        /// Part of macOS (Control Center's AirPlay receiver, rapportd…): never offered a Stop button.
        var isSystem: Bool {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
            let path = String(cString: buffer)
            return path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") || path.hasPrefix("/Library/Apple/")
        }
    }

    @Published private(set) var listeners: [Listener] = []
    @Published private(set) var loading = false
    @Published var listOpen = false

    func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            let found = await Self.scan()
            listeners = found
            loading = false
        }
    }

    /// Listening TCP sockets of this user's processes, one row per port and process.
    nonisolated static func scan() async -> [Listener] {
        // -F gives one field per line: p<pid>, c<command>, n<address:port>.
        let result = await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: 10)
        var rows: [Listener] = []
        var seen = Set<String>()
        var pid: pid_t = 0
        var command = ""
        for line in result.out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = pid_t(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                let key = "\(pid):\(port)"
                guard seen.insert(key).inserted else { continue }
                rows.append(Listener(port: port, pid: pid, command: command, address: address))
            default: break
            }
        }
        return rows.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    nonisolated static func listeners(on port: Int) async -> [Listener] {
        await scan().filter { $0.port == port }
    }

    /// Asks the process to quit (SIGTERM), then forces it if it's still there after a moment.
    func stop(_ listener: Listener) {
        if let app = listener.app, app.activationPolicy == .regular {
            app.terminate()
        } else {
            kill(listener.pid, SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if kill(listener.pid, 0) == 0, NSRunningApplication(processIdentifier: listener.pid)?.activationPolicy != .regular {
                kill(listener.pid, SIGKILL)
            }
            self?.refresh()
        }
        ActivityCenter.shared.show(.notice(title: "Stopped \(listener.displayName)", detail: "Port \(listener.port)",
                                           icon: "network.slash"), for: 3)
    }

    func open(_ listener: Listener) {
        if let url = URL(string: "http://localhost:\(listener.port)") { NSWorkspace.shared.open(url) }
    }
}

/// Port lookups for the search bar: `lsof` takes a moment, so the first keystroke starts it and
/// the suggestions refresh when it's done.
@MainActor
final class PortLookup {
    static let shared = PortLookup()
    private var cache: (date: Date, listeners: [PortScanner.Listener])?
    private var loading = false

    /// Listeners on a port, or nil while the lookup is still running.
    func listeners(for port: Int) -> [PortScanner.Listener]? {
        if let cache, Date().timeIntervalSince(cache.date) < 5 {
            return cache.listeners.filter { $0.port == port }
        }
        if !loading {
            loading = true
            Task {
                let all = await PortScanner.scan()
                cache = (Date(), all)
                loading = false
                SearchSuggestions.shared.refresh()
            }
        }
        return nil
    }

    func invalidate() { cache = nil }
}

/// Notices when a local dev server starts (`npm run dev`, `python -m http.server`, `rails s`…) and
/// offers to open it. Apps with windows and macOS's own services are ignored.
@MainActor
final class DevServerWatcher {
    static let shared = DevServerWatcher()
    private var timer: Timer?
    private var known: Set<String>?

    func apply(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        known = nil
        guard enabled else { return }
        scan()
        let t = Timer(timeInterval: 8, repeats: true) { _ in MainActor.assumeIsolated { DevServerWatcher.shared.scan() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func scan() {
        Task {
            let all = await PortScanner.scan()
            let candidates = all.filter { $0.port >= 1024 && !$0.isSystem && $0.app?.activationPolicy != .regular }
            let ids = Set(candidates.map(\.id))
            defer { known = ids }
            // The first scan is the baseline: servers already running don't announce themselves.
            guard let known else { return }
            let fresh = candidates.filter { !known.contains($0.id) }
            // One alert per process (Vite also opens a port for hot reload): its lowest port.
            let byProcess = Dictionary(grouping: fresh, by: \.pid).values.compactMap { $0.min { $0.port < $1.port } }
            guard let server = byProcess.min(by: { $0.port < $1.port }) else { return }
            let folder = Self.workingDirectory(of: server.pid).map { ($0 as NSString).lastPathComponent }
            let url = "http://localhost:" + String(server.port)
            NotchPresenter.shared.offer(Prompt(icon: "server.rack", tint: .systemGreen,
                                               title: "localhost:" + String(server.port) + " is up",
                                               detail: [server.command, folder].compactMap { $0 }.joined(separator: " · "),
                                               actions: [
                                                   .init(title: "Copy URL") {
                                                       NSPasteboard.general.clearContents()
                                                       NSPasteboard.general.setString(url, forType: .string)
                                                   },
                                                   .init(title: "Open", primary: true) { PortScanner.shared.open(server) },
                                               ]))
        }
    }

    /// The folder a process was started in (its project, for a dev server).
    nonisolated static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty || path == "/" ? nil : path
    }
}
