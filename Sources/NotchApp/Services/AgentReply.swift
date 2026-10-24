import AppKit

/// Answering a coding agent from the notch: what a waiting Claude Code session last said (or wants
/// to run), and sending a reply into that session's own terminal tab. Text is only ever typed into
/// the exact pane the session runs in: cmux by the pane ID it gives the process, Terminal and iTerm2
/// by its TTY through their scripting. Any other terminal gets the reply on the clipboard and is
/// brought forward instead, so nothing is ever typed into the wrong window.
enum AgentReply {
    enum Outcome { case sent, copied }

    // MARK: - What it said

    /// The last thing the session said, or the tool it's waiting to use, in a line or two.
    /// What it last said, and whether that's a tool waiting for permission (answered only in the terminal).
    struct Words { let text: String; let permission: Bool }

    nonisolated static func lastWords(sessionID: String, cwd: String) -> Words? {
        // Claude Code names the folder after the path with everything but letters and digits as "-".
        let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(folder)/\(sessionID).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return autoreleasepool {
            for line in tail.split(separator: "\n").reversed() {
                guard line.contains("\"assistant\""),
                      let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
                // A tool waiting for permission is what it needs you for.
                if let tool = content.last(where: { $0["type"] as? String == "tool_use" }) {
                    return Words(text: describe(tool["name"] as? String ?? "", tool["input"] as? [String: Any] ?? [:]), permission: true)
                }
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return Words(text: String(trimmed.suffix(300)), permission: false) }
            }
            return nil
        }
    }

    /// What a tool call would do, in a line: the command, the file, the page.
    nonisolated static func describe(_ tool: String, _ input: [String: Any]) -> String {
        func file(_ key: String) -> String? { (input[key] as? String).map { ($0 as NSString).lastPathComponent } }
        let text: String
        switch tool {
        case "Bash": text = (input["command"] as? String).map { "Run: \($0)" } ?? "Run a command"
        case "Edit", "MultiEdit": text = "Edit \(file("file_path") ?? "a file")"
        case "Write": text = "Write \(file("file_path") ?? "a file")"
        case "NotebookEdit": text = "Edit \(file("notebook_path") ?? "a notebook")"
        case "WebFetch": text = "Open \((input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a page")"
        case "WebSearch": text = (input["query"] as? String).map { "Search the web: \($0)" } ?? "Search the web"
        case "": text = "Use a tool"
        default:
            // mcp__server__tool reads as "server: tool".
            let parts = tool.components(separatedBy: "__")
            text = parts.count == 3 && parts[0] == "mcp" ? "Use \(parts[1]): \(parts[2])" : "Use \(tool)"
        }
        return String(text.replacingOccurrences(of: "\n", with: " ").prefix(160))
    }

    // MARK: - Going there

    /// Brings the session's own pane forward: cmux's by its ID, Terminal's or iTerm2's tab by its
    /// TTY. False when it can't tell which, and the caller brings the app forward instead.
    @MainActor static func reveal(_ session: AgentMonitor.Session) -> Bool {
        guard let pid = session.pid else { return false }
        return reveal(pid: pid)
    }

    /// The same for any process in a terminal (a shell that ran `notch run`, an agent's MCP server).
    @MainActor static func reveal(pid: pid_t) -> Bool {
        if let cmux = cmuxTarget(pid: pid) {
            if let workspace = cmux.workspace { _ = Shell.runSync(cmux.cli, ["select-workspace", "--workspace", workspace], timeout: 3) }
            guard Shell.runSync(cmux.cli, ["focus-panel", "--panel", cmux.panel] + (cmux.workspace.map { ["--workspace", $0] } ?? []), timeout: 3).ok else { return false }
            NSRunningApplication(processIdentifier: AppIdentity.responsiblePID(for: pid))?.activate()
            return true
        }
        guard let tty = tty(of: pid), let terminal = terminalApp(for: pid), let script = revealScript(for: terminal, tty: tty) else { return false }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil && result?.stringValue == "ok"
    }

    private static func revealScript(for bundleID: String, tty: String) -> String? {
        guard tty.range(of: #"^/dev/ttys?[0-9]{1,4}$"#, options: .regularExpression) != nil else { return nil }
        switch bundleID {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                tell t to select
                                tell s to select
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        default:
            return nil
        }
    }

    // MARK: - Replying

    /// Types the reply (and Return) into the session's own tab, or copies it and brings the
    /// terminal forward when the tab can't be found for certain.
    @MainActor static func send(_ text: String, to session: AgentMonitor.Session) -> Outcome {
        // One line: a newline would submit early.
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !reply.isEmpty else { return .copied }
        if let pid = session.pid, sendViaCmux(reply, pid: pid) { return .sent }
        if let pid = session.pid, let tty = tty(of: pid),
           let terminal = terminalApp(for: pid), let script = script(for: terminal, tty: tty, text: reply) {
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error == nil, result?.stringValue == "ok" { return .sent }
            DebugHooks.log("AgentReply: \(terminal) script failed: \(error ?? [:])")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reply, forType: .string)
        ClipboardHistory.shared.ignoreCurrent()
        AgentMonitor.shared.focus(session)
        return .copied
    }

    /// cmux gives every process in a pane CMUX_PANEL_ID (and its workspace); its CLI types into
    /// exactly that pane, and refuses to type over a half-written draft or into an open dialog.
    private static func sendViaCmux(_ text: String, pid: pid_t) -> Bool {
        guard let cmux = cmuxTarget(pid: pid) else { return false }
        let cli = cmux.cli
        let target = ["--panel", cmux.panel] + (cmux.workspace.map { ["--workspace", $0] } ?? [])
        // "\" stays literal: the CLI reads \n and \r as Enter.
        let literal = text.replacingOccurrences(of: "\\", with: "\\\\")
        guard Shell.runSync(cli, ["send-panel"] + target + ["--", literal], timeout: 5).ok else { return false }
        return Shell.runSync(cli, ["send-key-panel"] + target + ["enter"], timeout: 5).ok
    }

    /// The cmux pane a process runs in, and the CLI to reach it.
    private static func cmuxTarget(pid: pid_t) -> (cli: String, panel: String, workspace: String?)? {
        let env = environment(of: pid)
        guard let panel = env["CMUX_PANEL_ID"], !panel.isEmpty else { return nil }
        // The path comes from the agent's environment, which anything in that terminal can set:
        // only a cmux CLI inside a cmux.app in Applications runs (NotchApp's children share its
        // privacy permissions, so an arbitrary program must never be one of them).
        let cli = Self.trustedCmux(env["CMUX_BUNDLED_CLI_PATH"]) ?? "/Applications/cmux.app/Contents/Resources/bin/cmux"
        guard Self.trustedCmux(cli) != nil, FileManager.default.isExecutableFile(atPath: cli) else { return nil }
        let workspace = env["CMUX_WORKSPACE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        return (cli, panel, workspace)
    }

    private static func trustedCmux(_ path: String?) -> String? {
        guard let path else { return nil }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let roots = ["/Applications/cmux.app/", FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/cmux.app/"]
        return roots.contains(where: real.hasPrefix) && real.hasSuffix("/Contents/Resources/bin/cmux") ? real : nil
    }

    /// A process's environment (same user only), from `ps -E`. Values with spaces are cut at the
    /// first space; the IDs read here have none.
    private static func environment(of pid: pid_t) -> [String: String] {
        let out = Shell.runSync("/bin/ps", ["-wwE", "-p", "\(pid)", "-o", "command="], timeout: 2).out
        var env: [String: String] = [:]
        for token in out.split(separator: " ") where token.hasPrefix("CMUX_") {
            let parts = token.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { env[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return env
    }

    /// "/dev/ttys004" for the process, if it has a terminal.
    private static func tty(of pid: pid_t) -> String? {
        let out = Shell.runSync("/bin/ps", ["-o", "tty=", "-p", "\(pid)"], timeout: 2).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out != "??" else { return nil }
        return "/dev/" + out
    }

    /// The bundle ID of the terminal app the process runs in.
    @MainActor private static func terminalApp(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: AppIdentity.responsiblePID(for: pid))?.bundleIdentifier
    }

    private static func script(for bundleID: String, tty: String, text: String) -> String? {
        // The tty goes into the script's text, so it must be exactly a device name.
        guard tty.range(of: #"^/dev/ttys?[0-9]{1,4}$"#, options: .regularExpression) != nil else { return nil }
        let quoted = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        switch bundleID {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            do script "\(quoted)" in t
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                tell s to write text "\(quoted)"
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        default:
            return nil
        }
    }
}
