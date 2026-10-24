import AppKit

/// Claude Code's hooks, read-only: each event (a prompt sent, a tool about to run, a subagent
/// done, the turn over) runs `notch hook`, which passes it here. The notch then knows what each
/// session is doing right now, how many subagents it has out, and what it changed when it's done,
/// the moment it happens instead of at the next poll.
///
/// The hooks never answer for you: `notch hook` prints nothing and always exits 0, so Claude Code
/// carries on exactly as it would without them, permissions included (there's deliberately no
/// PermissionRequest hook). They're added to ~/.claude/settings.json only from the switch in
/// Settings › Agents, and taken out again by it.
@MainActor
final class AgentHooks: ObservableObject {
    static let shared = AgentHooks()

    /// What a session's hooks have said this turn.
    struct Live: Equatable {
        /// "Editing Pager.swift", "Running the tests"…; nil while it's thinking.
        var activity: String?
        var subagents = 0
        var turnStarted: Date?
        /// Files it edited this turn, by name, in order.
        var edited: [String] = []
        var lastEvent = Date()
    }

    /// By Claude Code's session ID.
    @Published private(set) var live: [String: Live] = [:]
    /// The hooks are in Claude Code's settings (read from the file; see `refreshInstalled`).
    @Published private(set) var installed = false

    private init() {}

    /// Sessions whose hooks are reporting: their own Banner says when they're done.
    func reports(_ sessionID: String) -> Bool {
        guard let s = live[sessionID] else { return false }
        return Date().timeIntervalSince(s.lastEvent) < 6 * 3600
    }

    // MARK: - Events

    func receive(_ event: [String: Any]) {
        guard let id = event["session_id"] as? String, !id.isEmpty, let name = event["hook_event_name"] as? String else { return }
        var s = live[id] ?? Live()
        s.lastEvent = Date()
        let tool = event["tool_name"] as? String ?? ""
        let input = event["tool_input"] as? [String: Any] ?? [:]
        switch name {
        case "SessionStart":
            s = Live()
        case "UserPromptSubmit":
            s = Live(turnStarted: Date())
        case "PreToolUse":
            if s.turnStarted == nil { s.turnStarted = Date() }
            if tool == "Task" || tool == "Agent" { s.subagents += 1 }
            s.activity = Self.activity(tool, input)
        case "PostToolUse":
            if ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(tool),
               let path = input["file_path"] as? String ?? input["notebook_path"] as? String {
                let file = (path as NSString).lastPathComponent
                if !s.edited.contains(file) { s.edited.append(file) }
            }
        case "SubagentStop":
            s.subagents = max(0, s.subagents - 1)
        case "Notification":
            s.activity = nil
        case "Stop":
            finished(id, s, cwd: event["cwd"] as? String)
            s = Live()
        case "SessionEnd":
            live[id] = nil
        default:
            break
        }
        if name != "SessionEnd", live[id] != s { live[id] = s }
        // The tool events only change what's shown beside a session; these change its state.
        if ["UserPromptSubmit", "Notification", "Stop", "SessionEnd"].contains(name) { AgentMonitor.shared.hookEvent() }
    }

    /// What a working session is doing, from its hooks.
    func live(for session: AgentMonitor.Session) -> Live? {
        guard session.state == .working, let id = session.claudeID else { return nil }
        return live[id]
    }

    /// The turn's over: a Banner with what it changed and how long it took (a click goes to its pane).
    private func finished(_ id: String, _ s: Live, cwd: String?) {
        guard AppSettings.shared.agentsEnabled, AppSettings.shared.agentAlerts, let started = s.turnStarted else { return }
        let session = AgentMonitor.shared.sessions.first { $0.claudeID == id }
        let project = session?.project ?? cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude Code"
        var parts: [String] = []
        switch s.edited.count {
        case 0: break
        case 1: parts.append("Edited \(s.edited[0])")
        case 2: parts.append("Edited \(s.edited[0]) and \(s.edited[1])")
        default: parts.append("Edited \(s.edited[0]) and \(s.edited.count - 1) more")
        }
        parts.append((parts.isEmpty ? "Took " : "") + CommandHandler.duration(Date().timeIntervalSince(started)))
        ActivityCenter.shared.show(.notice(title: "Claude Code finished · \(project)", detail: parts.joined(separator: " · "),
                                           icon: "sparkles.rectangle.stack.fill"), for: 5) {
            if let session = AgentMonitor.shared.sessions.first(where: { $0.claudeID == id }) { AgentMonitor.shared.focus(session) }
        }
    }

    /// What a tool call is doing, in a few words.
    static func activity(_ tool: String, _ input: [String: Any]) -> String {
        func file(_ key: String) -> String? { (input[key] as? String).map { ($0 as NSString).lastPathComponent } }
        switch tool {
        case "Bash":
            if let d = (input["description"] as? String)?.trimmingCharacters(in: .whitespaces), !d.isEmpty { return String(d.prefix(60)) }
            let command = (input["command"] as? String ?? "").split(separator: " ").first.map(String.init) ?? ""
            return command.isEmpty ? "Running a command" : "Running \(command)"
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing \(file("file_path") ?? file("notebook_path") ?? "a file")"
        case "Write": return "Writing \(file("file_path") ?? "a file")"
        case "Read": return "Reading \(file("file_path") ?? "a file")"
        case "Grep", "Glob", "LS": return "Searching the code"
        case "WebFetch", "WebSearch": return "Reading the web"
        case "Task", "Agent": return (input["description"] as? String).map { "Delegating: \($0.prefix(50))" } ?? "Delegating"
        case "TodoWrite": return "Planning"
        default:
            let parts = tool.components(separatedBy: "__")
            return parts.count == 3 && parts[0] == "mcp" ? "Using \(parts[1])" : "Using \(tool)"
        }
    }

    // MARK: - Installing

    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

    /// The events passed on. Tool events match every tool.
    private static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
                                 "Stop", "SubagentStop", "SessionEnd"]
    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    /// The hook's command: does nothing (and fails nothing) once NotchApp is gone.
    static func hookCommand(_ notch: URL = CommandBridge.commandURL) -> String {
        let quoted = "'" + notch.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "test -x \(quoted) && \(quoted) hook || true"
    }

    /// One of ours, whichever copy of NotchApp put it there.
    private static func isOurs(_ hook: Any) -> Bool {
        guard let command = (hook as? [String: Any])?["command"] as? String else { return false }
        return command.contains("/Contents/MacOS/notch' hook")
    }

    func refreshInstalled() {
        let now = Self.ourCommand(in: Self.settingsURL) != nil
        if installed != now { installed = now }
    }

    /// The command our hooks run, if they're in that settings file.
    private static func ourCommand(in url: URL) -> String? {
        guard let hooks = read(url)?["hooks"] as? [String: Any] else { return nil }
        for case let groups as [[String: Any]] in hooks.values {
            for group in groups {
                if let hook = (group["hooks"] as? [Any])?.first(where: isOurs) { return (hook as? [String: Any])?["command"] as? String }
            }
        }
        return nil
    }

    func setInstalled(_ on: Bool) throws {
        try Self.write(on, to: Self.settingsURL)
        refreshInstalled()
    }

    /// At launch: hooks left pointing at a copy of NotchApp that's gone (it moved) point here instead.
    func repairIfMoved() {
        refreshInstalled()
        guard let command = Self.ourCommand(in: Self.settingsURL), command != Self.hookCommand() else { return }
        let path = command.components(separatedBy: "'").dropFirst().first ?? ""
        guard !FileManager.default.isExecutableFile(atPath: path) else { return }
        try? Self.write(true, to: Self.settingsURL)
    }

    /// Adds our hooks to (or takes them out of) a Claude Code settings file, leaving everything
    /// else in it as it was. The first change keeps a copy of the file beside it.
    static func write(_ on: Bool, to url: URL) throws {
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            guard let existing = read(url) else { throw HookError.unreadable }
            settings = existing
            let backup = url.appendingPathExtension("notchapp-backup")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: url, to: backup) }
        } else if !on {
            return
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            // Ours out of every group (dropping groups left empty); everyone else's stay as they were.
            var groups = (hooks[event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                guard let list = group["hooks"] as? [Any] else { return group }
                let kept = list.filter { !isOurs($0) }
                if kept.isEmpty, !list.isEmpty { return nil }
                var g = group
                g["hooks"] = kept
                return g
            }
            if on {
                var group: [String: Any] = ["hooks": [["type": "command", "command": hookCommand(), "timeout": 5]]]
                if toolEvents.contains(event) { group["matcher"] = "*" }
                groups.append(group)
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    enum HookError: LocalizedError {
        case unreadable
        var errorDescription: String? { "~/.claude/settings.json isn't valid JSON, so it was left alone." }
    }
}
