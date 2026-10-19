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
    nonisolated static func lastWords(sessionID: String, cwd: String) -> String? {
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
                    let name = tool["name"] as? String ?? "a tool"
                    let input = tool["input"] as? [String: Any] ?? [:]
                    let what = (input["command"] ?? input["file_path"] ?? input["url"] ?? input["description"]) as? String
                    return "Wants to use \(name)" + (what.map { ": " + String($0.prefix(160)) } ?? "")
                }
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.suffix(300)) }
            }
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
        let env = environment(of: pid)
        guard let panel = env["CMUX_PANEL_ID"], !panel.isEmpty else { return false }
        // The path comes from the agent's environment, which anything in that terminal can set:
        // only a cmux CLI inside a cmux.app in Applications runs (NotchApp's children share its
        // privacy permissions, so an arbitrary program must never be one of them).
        let cli = Self.trustedCmux(env["CMUX_BUNDLED_CLI_PATH"]) ?? "/Applications/cmux.app/Contents/Resources/bin/cmux"
        guard Self.trustedCmux(cli) != nil, FileManager.default.isExecutableFile(atPath: cli) else { return false }
        var target = ["--panel", panel]
        if let workspace = env["CMUX_WORKSPACE_ID"], !workspace.isEmpty { target += ["--workspace", workspace] }
        // "\" stays literal: the CLI reads \n and \r as Enter.
        let literal = text.replacingOccurrences(of: "\\", with: "\\\\")
        guard Shell.runSync(cli, ["send-panel"] + target + ["--", literal], timeout: 5).ok else { return false }
        return Shell.runSync(cli, ["send-key-panel"] + target + ["enter"], timeout: 5).ok
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
