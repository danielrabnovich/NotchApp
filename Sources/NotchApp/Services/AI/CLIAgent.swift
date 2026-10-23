import AppKit
import Foundation

/// Uses the Claude Code or Codex command-line tool the person already has, signed in with their own
/// Claude or ChatGPT plan, instead of an API key.
///
/// NotchApp never sees, copies or stores that login. It runs the official CLI headless, the way
/// editors and terminals with "use your subscription" support do, and reads the CLI's JSON event
/// stream. The CLI keeps owning sign-in, model access, usage limits and updates, so nothing here
/// breaks when Anthropic or OpenAI change how their logins work.
///
/// Each run is kept small and contained: no tools, no MCP servers, no hooks or user settings, no
/// saved session, in an empty working folder, so a quick question in the notch doesn't turn into
/// an agent session, show up in the Agents tab, or touch the person's files.
enum CLIAgent {
    enum Tool: String, Sendable {
        case claude, codex

        var name: String { self == .claude ? "Claude Code" : "Codex" }
        var command: String { self == .claude ? "claude" : "codex" }
        /// Where its own requests go, for privacy lines ("Sent to Anthropic").
        var company: String { self == .claude ? "Anthropic" : "OpenAI" }
        var plan: String { self == .claude ? "Claude" : "ChatGPT" }

        var installURL: URL {
            URL(string: self == .claude ? "https://code.claude.com/docs/en/setup" : "https://developers.openai.com/codex/cli")!
        }

        /// The CLI's own sign-in command, run in Terminal so its browser login works as usual.
        var loginArguments: [String] { self == .claude ? ["auth", "login"] : ["login"] }

        /// Models offered in Settings, as the CLI's own names ("" is the CLI's default). Codex's
        /// list depends on the plan, so it gets a text field instead.
        var suggestedModels: [ModelChoice] {
            switch self {
            case .claude: [ModelChoice(id: "", title: "Claude Code's default"), ModelChoice(id: "fable", title: "Fable (smartest)"),
                           ModelChoice(id: "opus", title: "Opus"), ModelChoice(id: "sonnet", title: "Sonnet (balanced)"),
                           ModelChoice(id: "haiku", title: "Haiku (fastest)")]
            case .codex: []
            }
        }
    }

    struct ModelChoice: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
    }

    struct Config: Sendable {
        let tool: Tool
        let executable: String
        /// Empty: whatever the CLI picks by default.
        let model: String
        let environment: [String: String]
    }

    struct CLIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Availability: Equatable, Sendable {
        case ready
        case notInstalled
        case signedOut
    }

    // MARK: - Active config

    /// The CLI in use, or nil when another provider is chosen (or the CLI can't be found).
    static func active() async -> Config? {
        let (provider, model, custom) = await MainActor.run {
            let s = AppSettings.shared
            return (s.aiProvider, s.cloudModel(for: s.aiProvider), s.cliPaths[s.aiProvider.rawValue] ?? "")
        }
        guard let tool = provider.cliTool, let exe = await Locator.shared.executable(for: tool, custom: custom) else { return nil }
        return Config(tool: tool, executable: exe, model: model.trimmingCharacters(in: .whitespaces),
                      environment: await Locator.shared.environment(for: exe))
    }

    // MARK: - Status

    /// Whether the CLI is installed and signed in. Cached for a minute: Settings and the Search tab
    /// ask often, and each check starts a process.
    static func availability(_ tool: Tool, refresh: Bool = false) async -> Availability {
        let custom = await MainActor.run { AppSettings.shared.cliPaths[tool.providerRawValue] ?? "" }
        if !refresh, let cached = await Locator.shared.cachedAvailability(tool) { return cached }
        guard let exe = await Locator.shared.executable(for: tool, custom: custom, refresh: refresh) else {
            await Locator.shared.store(.notInstalled, for: tool)
            return .notInstalled
        }
        let env = await Locator.shared.environment(for: exe)
        let result: Availability
        switch tool {
        case .claude:
            // `claude auth status` prints JSON with "loggedIn". Older versions without the command
            // are assumed signed in; the first request explains if they aren't.
            let r = await run(exe, ["auth", "status", "--json"], env: env, timeout: 15)
            if let obj = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
               let loggedIn = obj["loggedIn"] as? Bool {
                result = loggedIn ? .ready : .signedOut
            } else {
                result = r.out.localizedCaseInsensitiveContains("not logged in") ? .signedOut : .ready
            }
        case .codex:
            // `codex login status` exits 0 when signed in (ChatGPT or an API key saved in Codex).
            let r = await run(exe, ["login", "status"], env: env, timeout: 15)
            result = r.code == 0 ? .ready : .signedOut
        }
        await Locator.shared.store(result, for: tool)
        return result
    }

    /// Where the CLI was found, for Settings.
    static func executablePath(_ tool: Tool) async -> String? {
        let custom = await MainActor.run { AppSettings.shared.cliPaths[tool.providerRawValue] ?? "" }
        return await Locator.shared.executable(for: tool, custom: custom)
    }

    /// Opens Terminal on the CLI's own sign-in, so its usual browser login runs. NotchApp only
    /// checks the result afterwards; it never handles the credentials.
    @MainActor static func openSignIn(_ tool: Tool) {
        Task {
            let custom = AppSettings.shared.cliPaths[tool.providerRawValue] ?? ""
            let exe = await Locator.shared.executable(for: tool, custom: custom) ?? tool.command
            let script = "#!/bin/zsh -l\n" + ([exe] + tool.loginArguments).map(shellQuoted).joined(separator: " ") + "\n"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("NotchApp-\(tool.command)-login.command")
            do {
                try script.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                NSWorkspace.shared.open(url)
            } catch {
                DebugHooks.log("CLIAgent: couldn't open sign-in: \(error)")
            }
            await Locator.shared.forget(tool)
        }
    }

    // MARK: - Chat

    /// Streams one reply, calling `onText` with the full text so far; returns the final text.
    /// `quick` marks short structured calls (routing, planning) that should spend little effort.
    @discardableResult
    static func stream(_ c: Config, system: String, user: String, images: [Data], json: Bool = false, quick: Bool = false,
                       onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        // Without its own instructions the CLI would fall back to its coding-agent prompt.
        var instructions = system.isEmpty ? "You are a helpful assistant. Answer clearly and concisely." : system
        instructions += "\nYou are answering inside a small Mac app, not a coding session: reply with text only and don't use tools."
        if json { instructions += "\nReply with ONLY the JSON object: no prose, no code fences." }
        switch c.tool {
        case .claude: return try await claude(c, system: instructions, user: user, images: images, quick: quick || json, onText: onText)
        case .codex: return try await codex(c, system: instructions, user: user, images: images, quick: quick || json, onText: onText)
        }
    }

    // MARK: Claude Code

    /// `claude -p` with stream-json in and out: the message (and any pictures) goes in on stdin,
    /// and text arrives as Messages API stream events.
    private static func claude(_ c: Config, system: String, user: String, images: [Data], quick: Bool,
                               onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        var args = ["-p",
                    "--input-format", "stream-json",
                    "--output-format", "stream-json",
                    "--include-partial-messages", "--verbose",
                    // A plain answer: no tools, MCP servers, slash commands, hooks or saved session.
                    "--tools", "",
                    "--strict-mcp-config",
                    "--setting-sources", "",
                    "--disable-slash-commands",
                    "--no-session-persistence",
                    "--system-prompt", system]
        if !c.model.isEmpty { args += ["--model", c.model] }
        if quick { args += ["--effort", "low"] }

        var content: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
        }
        content.append(["type": "text", "text": user])
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var payload = try JSONSerialization.data(withJSONObject: message)
        payload.append(0x0A)

        let state = StreamState()
        let outcome = try await runStreaming(c, args: args, stdin: payload) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            switch obj["type"] as? String {
            case "stream_event":
                let event = obj["event"] as? [String: Any]
                switch event?["type"] as? String {
                case "content_block_delta":
                    let delta = event?["delta"] as? [String: Any]
                    if delta?["type"] as? String == "text_delta", let t = delta?["text"] as? String {
                        if let soFar = state.append(t) { await onText(soFar) }
                    }
                case "message_delta":
                    if (event?["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" { state.refused = true }
                default: break
                }
            case "result":
                let text = obj["result"] as? String ?? ""
                if obj["is_error"] as? Bool == true { state.error = text.isEmpty ? "Claude Code stopped with an error." : text }
                else { state.result = text }
            default: break
            }
        }
        if let error = state.error { throw CLIError(message: friendly(error, tool: .claude)) }
        if state.refused { throw CLIError(message: "The model declined to answer that.") }
        let final = (state.text.isEmpty ? state.result ?? "" : state.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty, outcome.code != 0 {
            throw CLIError(message: friendly(outcome.stderr.isEmpty ? "Claude Code exited with code \(outcome.code)." : outcome.stderr, tool: .claude))
        }
        await onText(final)
        return final
    }

    // MARK: Codex

    /// `codex exec --json`: the prompt goes in on stdin and the reply arrives as an
    /// `agent_message` item. Codex sends whole messages rather than token deltas.
    private static func codex(_ c: Config, system: String, user: String, images: [Data], quick: Bool,
                              onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        let work = try workFolder()
        // Pictures go in as files; removed once the run ends.
        var imageFiles: [URL] = []
        defer { imageFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        for data in images {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchapp-\(UUID().uuidString).jpg")
            try data.write(to: url)
            imageFiles.append(url)
        }

        var args = ["exec", "--json",
                    // A plain answer: nothing saved, no user config (MCP servers, profiles), no
                    // exec rules, and a read-only sandbox in an empty folder.
                    "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                    "--color", "never",
                    "--sandbox", "read-only",
                    "--cd", work.path,
                    "-c", "developer_instructions=" + tomlString(system)]
        if !c.model.isEmpty { args += ["--model", c.model] }
        if quick { args += ["-c", "model_reasoning_effort=\"low\""] }
        args += imageFiles.map { "--image=" + $0.path }
        args.append("-")   // the prompt comes from stdin

        let state = StreamState()
        let outcome = try await runStreaming(c, args: args, stdin: Data(user.utf8)) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            switch obj["type"] as? String {
            case "item.started", "item.updated", "item.completed":
                let item = obj["item"] as? [String: Any]
                if item?["type"] as? String == "agent_message", let t = item?["text"] as? String {
                    state.text = t
                    await onText(t)
                }
            case "turn.failed":
                let error = (obj["error"] as? [String: Any])?["message"] as? String
                state.error = error ?? "Codex stopped with an error."
            case "error":
                // Often a passing "Reconnecting…": kept in case the run then fails.
                state.lastNotice = obj["message"] as? String
            default: break
            }
        }
        if let error = state.error { throw CLIError(message: friendly(error, tool: .codex)) }
        let final = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty {
            let why = state.lastNotice ?? (outcome.stderr.isEmpty ? "Codex exited with code \(outcome.code)." : outcome.stderr)
            throw CLIError(message: friendly(why, tool: .codex))
        }
        await onText(final)
        return final
    }

    // MARK: - Running

    /// What a streaming run's events add up to.
    private final class StreamState: @unchecked Sendable {
        var text = ""
        var result: String?
        var error: String?
        var lastNotice: String?
        var refused = false
        private var lastEmit = Date.distantPast

        /// Adds a piece of text; returns the text so far when it's time to show it (about 20 times a second).
        func append(_ piece: String) -> String? {
            text += piece
            guard Date().timeIntervalSince(lastEmit) > 0.05 else { return nil }
            lastEmit = Date()
            return text
        }
    }

    private struct Outcome { let code: Int32; let stderr: String }

    /// Lets cancellation and the time limit stop a running CLI.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
        func stop() { if process.isRunning { process.terminate() } }
    }

    /// Collects the end of stderr for error messages, from the pipe's handler thread.
    private final class Tail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func add(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(d)
            if data.count > 8000 { data = data.suffix(4000) }
        }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs the CLI, feeding `stdin` and handing each stdout line to `onLine`. Stops the process
    /// if the task is cancelled or it runs past the time limit.
    private static func runStreaming(_ c: Config, args: [String], stdin: Data, timeout: TimeInterval = 300,
                                     onLine: @escaping @Sendable (String) async -> Void) async throws -> Outcome {
        let box = ProcessBox()
        let p = box.process
        p.executableURL = URL(fileURLWithPath: c.executable)
        p.arguments = args
        p.environment = c.environment
        p.currentDirectoryURL = try workFolder()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        let tail = Tail()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty { tail.add(d) }
        }
        do {
            try p.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            throw CLIError(message: "Couldn't start \(c.tool.name) at \(c.executable).")
        }
        // Written off this task so a large prompt (pictures) can't block on a full pipe.
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: stdin)
            try? writer.close()
        }
        let killer = DispatchWorkItem { box.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer {
            killer.cancel()
            errors.fileHandleForReading.readabilityHandler = nil
        }

        try await withTaskCancellationHandler {
            for try await line in output.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                await onLine(line)
            }
        } onCancel: {
            box.stop()
        }
        p.waitUntilExit()
        try Task.checkCancellation()
        return Outcome(code: p.terminationStatus, stderr: String(tail.text.suffix(600)))
    }

    /// Runs a short CLI command (status checks) and returns its exit code and output.
    private static func run(_ exe: String, _ args: [String], env: [String: String], timeout: TimeInterval) async -> (code: Int32, out: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.environment = env
                p.currentDirectoryURL = try? workFolder()
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { continuation.resume(returning: (-1, "")); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// An empty folder the CLIs run in, so they find no project files, CLAUDE.md or git repo.
    private static func workFolder() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("NotchApp/CLI", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Helpers

    /// Turns the CLIs' errors into something to act on.
    static func friendly(_ raw: String, tool: Tool) -> String {
        let m = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = m.lowercased()
        if ["not logged in", "please run /login", "log in", "login", "unauthorized", "401", "authentication",
            "invalid api key", "oauth token"].contains(where: lower.contains) {
            return "\(tool.name) isn't signed in. Sign in from Settings → Search."
        }
        if ["usage limit", "rate limit", "limit reached", "429", "quota"].contains(where: lower.contains) {
            return "Your \(tool.plan) plan's usage limit is reached for now. \(m)"
        }
        return m.isEmpty ? "\(tool.name) stopped with an error." : "\(tool.name): \(m)"
    }

    /// A TOML basic string. A JSON string literal is one (same escapes), so JSON encoding does it.
    static func tomlString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Finding the CLI

extension CLIAgent {
    /// Finds the CLI and the PATH it needs. Apps opened from the Dock don't get the shell's PATH,
    /// so an npm-installed CLI (which needs `node`) wouldn't run without the login shell's.
    actor Locator {
        static let shared = Locator()

        private var executables: [Tool: String] = [:]
        private var availability: [Tool: (value: Availability, at: Date)] = [:]
        private var shellPATH: String?

        func executable(for tool: Tool, custom: String, refresh: Bool = false) async -> String? {
            let custom = (custom as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces)
            if !custom.isEmpty { return FileManager.default.isExecutableFile(atPath: custom) ? custom : nil }
            if !refresh, let known = executables[tool], FileManager.default.isExecutableFile(atPath: known) { return known }
            let home = NSHomeDirectory()
            var candidates: [String] = switch tool {
            case .claude: ["\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
                           "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
                           "\(home)/.volta/bin/claude"]
            case .codex: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                          "\(home)/.npm-global/bin/codex", "\(home)/.bun/bin/codex", "\(home)/.volta/bin/codex",
                          "/Applications/Codex.app/Contents/Resources/codex"]
            }
            candidates += await loginShellPATH().split(separator: ":").map { "\($0)/\(tool.command)" }
            let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            executables[tool] = found
            return found
        }

        /// The environment for a CLI run: the login shell's PATH (plus the CLI's own folder), and
        /// no API keys, so the CLI uses the plan it's signed in with rather than billing a key that
        /// happens to be in the environment.
        func environment(for executable: String) async -> [String: String] {
            var env = ProcessInfo.processInfo.environment
            for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY",
                        // Set inside a Claude Code session; would make the CLI think it's nested.
                        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
                env.removeValue(forKey: key)
            }
            let dir = (executable as NSString).deletingLastPathComponent
            env["PATH"] = ([dir, await loginShellPATH(), "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"])
                .filter { !$0.isEmpty }.joined(separator: ":")
            env["NO_COLOR"] = "1"
            env["TERM"] = "dumb"
            return env
        }

        func cachedAvailability(_ tool: Tool) -> Availability? {
            guard let entry = availability[tool], Date().timeIntervalSince(entry.at) < 60 else { return nil }
            return entry.value
        }

        func store(_ value: Availability, for tool: Tool) { availability[tool] = (value, Date()) }

        func forget(_ tool: Tool) {
            availability[tool] = nil
            executables[tool] = nil
        }

        /// The PATH an interactive login shell sets up (nvm, Homebrew, Volta…), read once.
        private func loginShellPATH() async -> String {
            if let shellPATH { return shellPATH }
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            let marker = "__NOTCHAPP_PATH__"
            let r = await CLIAgent.run(shell, ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""],
                                       env: ProcessInfo.processInfo.environment, timeout: 5)
            var path = ""
            let parts = r.out.components(separatedBy: marker)
            if parts.count >= 3 { path = parts[1] }
            shellPATH = path
            return path
        }
    }
}

extension CLIAgent.Tool {
    var providerRawValue: String { self == .claude ? AIProvider.claudeCode.rawValue : AIProvider.codex.rawValue }
}
