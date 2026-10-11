import AppKit
import SQLite3
import SwiftUI

/// Coding agents running on this Mac (Claude Code, Codex, OpenCode, ZCode): which sessions are
/// working or waiting for you, and how many tokens each tool has used today. Reads only the
/// files and databases these tools already keep locally; nothing is sent anywhere.
@MainActor
final class AgentMonitor: ObservableObject {
    static let shared = AgentMonitor()

    enum Tool: String, CaseIterable, Identifiable, Codable {
        case claude, codex, opencode, zcode
        var id: String { rawValue }

        var name: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .opencode: "OpenCode"
            case .zcode: "ZCode"
            }
        }

        var tint: Color {
            switch self {
            case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
            case .codex: Color(red: 0.55, green: 0.6, blue: 1)
            case .opencode: Color(red: 0.95, green: 0.95, blue: 0.95)
            case .zcode: Color(red: 0.3, green: 0.75, blue: 1)
            }
        }

        var glyph: String {
            switch self {
            case .claude: "asterisk"
            case .codex: "chevron.left.forwardslash.chevron.right"
            case .opencode: "terminal.fill"
            case .zcode: "z.square.fill"
            }
        }

        /// The desktop app to bring forward, when the tool has one.
        var appBundleIDs: [String] {
            switch self {
            case .claude: ["com.anthropic.claudefordesktop"]
            case .codex: ["com.openai.codex"]
            case .opencode: ["ai.opencode.desktop"]
            case .zcode: ["ai.z.zcode", "com.zhipu.zcode", "ai.zcode.desktop"]
            }
        }
    }

    struct Session: Identifiable, Equatable {
        enum State: Equatable { case working, waiting, idle }
        let id: String
        let tool: Tool
        let title: String
        let directory: String?
        let state: State
        let updated: Date
        var pid: pid_t?
        var model: String?
        /// While waiting: what it last said, or the tool it wants to use (Claude Code).
        var lastWords: String?

        var project: String { directory.map { ($0 as NSString).lastPathComponent } ?? title }
    }

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var installed: Set<Tool> = []

    private var timer: Timer?
    private var tick = 0
    private var viewers = 0
    private var liveDemand = false
    private var lastStates: [String: Session.State] = [:]

    private init() {}

    var working: [Session] { sessions.filter { $0.state == .working } }
    var waiting: [Session] { sessions.filter { $0.state == .waiting } }
    var activeCount: Int { sessions.filter { $0.state != .idle }.count }

    // MARK: - Demand

    func start() { update() }

    func viewerAppeared() { viewers += 1; update(); AgentUsageStore.shared.refresh() }
    func viewerDisappeared() { viewers = max(0, viewers - 1); update() }

    func setLiveDemand(_ wanted: Bool) {
        guard wanted != liveDemand else { return }
        liveDemand = wanted
        update()
    }

    /// Polls while anything shows agents, or alerts are on.
    func update() {
        let s = AppSettings.shared
        let wanted = s.agentsEnabled && (viewers > 0 || liveDemand || s.agentAlerts || s.agentsKeepAwake)
        if wanted, timer == nil {
            refreshSessions()
            AgentUsageStore.shared.refresh()
            let t = Timer(timeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { AgentMonitor.shared.poll() } }
            t.tolerance = 0.6 // lets macOS batch this wake-up with others
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !wanted, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    private func poll() {
        tick += 1
        refreshSessions()
        // Usage means reading transcripts: once a minute, or every 15 s while the tab is open.
        if tick % (viewers > 0 ? 5 : 20) == 0 { AgentUsageStore.shared.refresh() }
    }

    // MARK: - Sessions

    func refreshSessions() {
        Task {
            async let claude = Task.detached { Self.claudeSessions() }.value
            async let codex = Task.detached { Self.codexSessions() }.value
            async let opencode = Task.detached { Self.opencodeSessions() }.value
            async let zcode = Task.detached { Self.zcodeSessions() }.value
            let all = await (claude + codex + opencode + zcode)
                .sorted { ($0.state.rank, $1.updated) < ($1.state.rank, $0.updated) }
            installed = Set(Tool.allCases.filter(Self.isInstalled))
            announceChanges(all)
            holdAwake(working: all.contains { $0.state == .working })
            if all != sessions { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { sessions = all } }
        }
    }

    private var lastWorking: Date?
    /// Turned off by hand while agents were working: don't turn it back on until they've stopped.
    private var awakeDeclined = false

    /// Keeps the Mac awake while any agent is working, and lets it sleep two minutes after the last
    /// one stops. A Keep Awake session you started yourself is left alone.
    private func holdAwake(working: Bool) {
        let keepAwake = KeepAwake.shared
        guard AppSettings.shared.agentsEnabled, AppSettings.shared.agentsKeepAwake else {
            if keepAwake.forAgents { keepAwake.stop(announce: false) }
            return
        }
        // Stopped by hand mid-run: respect that until the agents finish.
        if working, wasHolding, !keepAwake.isActive { awakeDeclined = true }
        if working {
            lastWorking = Date()
            if !keepAwake.isActive, !awakeDeclined {
                keepAwake.start(.indefinitely, forAgents: true)
            }
        } else if let last = lastWorking, Date().timeIntervalSince(last) > 120 {
            lastWorking = nil
            awakeDeclined = false
            if keepAwake.forAgents {
                keepAwake.stop(announce: false)
                ActivityCenter.shared.show(.notice(title: "Agents are done", detail: "Your Mac can sleep again", icon: "moon.zzz.fill", tone: .info), for: 3)
            }
        }
        wasHolding = keepAwake.forAgents
    }

    private var wasHolding = false

    /// A heads-up when a session finishes its work or starts waiting on you.
    private func announceChanges(_ all: [Session]) {
        defer { lastStates = Dictionary(all.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }) }
        guard AppSettings.shared.agentAlerts, !lastStates.isEmpty else { return }
        for session in all {
            guard let before = lastStates[session.id], before != session.state else { continue }
            if session.state == .waiting {
                // A Prompt: what it said, with Reply (in the Agents tab) and Go to Terminal.
                let words = session.lastWords.map { String($0.prefix(120)) }
                NotchPresenter.shared.offer(Prompt(
                    icon: "hand.raised.fill", tint: .systemOrange,
                    title: "\(session.tool.name) needs you · \(session.project)",
                    detail: words ?? "It's waiting for your answer.",
                    actions: [
                        .init(title: "Reply", primary: true) { NotchPresenter.shared.open(tab: .agents) },
                        .init(title: "Go to Terminal") { AgentMonitor.shared.focus(session) },
                    ]))
            } else if before == .working, session.state == .idle {
                ActivityCenter.shared.show(.notice(title: "\(session.tool.name) finished", detail: session.project, icon: "sparkles.rectangle.stack.fill"), for: 4)
            }
        }
    }

    nonisolated private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    nonisolated private static func isInstalled(_ tool: Tool) -> Bool {
        let fm = FileManager.default
        switch tool {
        case .claude: return fm.fileExists(atPath: home.appendingPathComponent(".claude/projects").path)
        case .codex: return fm.fileExists(atPath: home.appendingPathComponent(".codex").path)
        case .opencode: return fm.fileExists(atPath: home.appendingPathComponent(".local/share/opencode/opencode.db").path)
        case .zcode: return fm.fileExists(atPath: home.appendingPathComponent(".zcode/cli/db/db.sqlite").path)
        }
    }

    /// Claude Code registers each running session in ~/.claude/sessions/<pid>.json with its status.
    nonisolated private static func claudeSessions() -> [Session] {
        let folder = home.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> Session? in
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let pid = pid_t(string(obj["pid"]) ?? "") ?? 0
            // The file outlives a crashed session; only count processes that are still there.
            guard pid > 0, kill(pid, 0) == 0 else { return nil }
            let status = (string(obj["status"]) ?? "").lowercased()
            let state: Session.State = status == "busy" || status == "working" || status == "running" ? .working
                : status.isEmpty || status == "idle" ? .idle : .waiting
            let updated = (Double(string(obj["statusUpdatedAt"]) ?? string(obj["updatedAt"]) ?? "") ?? 0) / 1000
            let cwd = string(obj["cwd"])
            let sessionID = string(obj["sessionId"])
            var session = Session(id: "claude:\(sessionID ?? "\(pid)")", tool: .claude,
                                  title: string(obj["name"]) ?? cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude Code",
                                  directory: cwd, state: state, updated: Date(timeIntervalSince1970: updated), pid: pid)
            if state == .waiting, let sessionID, let cwd {
                session.lastWords = AgentReply.lastWords(sessionID: sessionID, cwd: cwd)
            }
            return session
        }
    }

    /// Codex writes a rollout file per session under ~/.codex/sessions/YYYY/MM/DD; one being
    /// written in the last half minute is a session at work.
    nonisolated private static func codexSessions() -> [Session] {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let folder = home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0))
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let running = !pids(matching: "codex").isEmpty
        return files.filter { $0.pathExtension == "jsonl" }.compactMap { url in
            let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            let age = Date().timeIntervalSince(modified)
            guard age < 3600 else { return nil }
            let meta = codexMeta(url)
            let state: Session.State = running && age < 30 ? .working : .idle
            return Session(id: "codex:\(url.lastPathComponent)", tool: .codex, title: meta.cwd.map { ($0 as NSString).lastPathComponent } ?? "Codex",
                           directory: meta.cwd, state: state, updated: modified, model: meta.model)
        }
    }

    nonisolated private static func codexMeta(_ url: URL) -> (cwd: String?, model: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 16_384), as: UTF8.self)
        var cwd: String?, model: String?
        for line in head.split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let payload = obj["payload"] as? [String: Any] ?? obj
            cwd = cwd ?? string(payload["cwd"])
            model = model ?? string(payload["model"])
        }
        return (cwd, model)
    }

    /// OpenCode keeps sessions in SQLite; a session touched in the last 20 seconds is working.
    nonisolated private static func opencodeSessions() -> [Session] {
        let path = home.appendingPathComponent(".local/share/opencode/opencode.db").path
        let cutoff = Int64((Date().timeIntervalSince1970 - 3600) * 1000)
        let rows = query(path, """
            select id, title, directory, model, time_updated from session
            where parent_id is null and time_archived is null and time_updated > \(cutoff)
            order by time_updated desc limit 8
            """)
        return rows.map { r in
            let updated = Date(timeIntervalSince1970: Double(r[4].int) / 1000)
            return Session(id: "opencode:\(r[0].text ?? "")", tool: .opencode, title: r[1].text ?? "OpenCode", directory: r[2].text,
                           state: Date().timeIntervalSince(updated) < 20 ? .working : .idle, updated: updated, model: r[3].text)
        }
    }

    /// ZCode's CLI database records every turn; one still "running" is a session at work.
    nonisolated private static func zcodeSessions() -> [Session] {
        let path = home.appendingPathComponent(".zcode/cli/db/db.sqlite").path
        let cutoff = Int64((Date().timeIntervalSince1970 - 3600) * 1000)
        let rows = query(path, """
            select s.id, s.title, s.directory, s.time_updated,
                   exists(select 1 from turn_usage t where t.session_id = s.id and t.status = 'running'
                          and t.started_at > \(cutoff - 6 * 3_600_000)) as running
            from session s
            where s.parent_id is null and s.time_archived is null and s.time_updated > \(cutoff)
            order by s.time_updated desc limit 8
            """)
        return rows.map { r in
            Session(id: "zcode:\(r[0].text ?? "")", tool: .zcode, title: r[1].text ?? "ZCode", directory: r[2].text,
                    state: r[4].int == 1 ? .working : .idle, updated: Date(timeIntervalSince1970: Double(r[3].int) / 1000))
        }
    }

    // MARK: - Actions

    /// Brings the session forward: the terminal it runs in, or the tool's own app.
    func focus(_ session: Session) {
        if let pid = session.pid {
            let owner = AppIdentity.responsiblePID(for: pid)
            if let app = NSRunningApplication(processIdentifier: owner), app.activationPolicy == .regular {
                app.activate()
                return
            }
            // Walk up to the first ancestor that's an app (the terminal).
            var current = pid
            for _ in 0..<12 {
                let parent = Self.parentPID(of: current)
                guard parent > 1 else { break }
                if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                    app.activate()
                    return
                }
                current = parent
            }
        }
        for id in session.tool.appBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                return
            }
        }
        if let dir = session.directory { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
    }

    func openFolder(_ session: Session) {
        guard let dir = session.directory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
    }

    /// Asks a session's process to stop (SIGINT, like pressing Ctrl-C).
    func interrupt(_ session: Session) {
        guard let pid = session.pid else { return }
        kill(pid, SIGINT)
    }

    // MARK: - Helpers

    nonisolated private static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    nonisolated private static func pids(matching name: String) -> [pid_t] {
        runningCommands().filter { $0.name == name }.map(\.pid)
    }

    nonisolated private static func runningCommands() -> [(pid: pid_t, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { p in
            var comm = p.kp_proc.p_comm
            let name = withUnsafePointer(to: &comm) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) } }
            return (p.kp_proc.p_pid, name)
        }
    }

    nonisolated private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    nonisolated private static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? Int(v as? String ?? "") ?? 0 }

    struct Value {
        let text: String?
        let int: Int
    }

    /// Read-only query against another app's database (immutable, so it never takes a lock on it).
    nonisolated static func query(_ path: String, _ sql: String) -> [[Value]] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var db: OpaquePointer?
        // Plain read-only first (sees the latest WAL writes); immutable as a fallback.
        let uris = ["file:\(path)?mode=ro", "file:\(path)?immutable=1"]
        for uri in uris {
            if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
                sqlite3_busy_timeout(db, 300)
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    var rows: [[Value]] = []
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let n = sqlite3_column_count(stmt)
                        rows.append((0..<n).map { i in
                            let text = sqlite3_column_text(stmt, i).map { String(cString: $0) }
                            return Value(text: text, int: Int(sqlite3_column_int64(stmt, i)))
                        })
                    }
                    sqlite3_finalize(stmt)
                    sqlite3_close(db)
                    return rows
                }
                sqlite3_finalize(stmt)
            }
            sqlite3_close(db)
            db = nil
        }
        return []
    }
}

private extension AgentMonitor.Session.State {
    var rank: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .idle: 2
        }
    }
}

/// "1.2M", "48k", "930".
func formatTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000_000...: String(format: "%.1fB", Double(n) / 1e9)
    case 10_000_000...: String(format: "%.0fM", Double(n) / 1e6)
    case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
    case 10_000...: String(format: "%.0fk", Double(n) / 1e3)
    case 1_000...: String(format: "%.1fk", Double(n) / 1e3)
    default: "\(n)"
    }
}
