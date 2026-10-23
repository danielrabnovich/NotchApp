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

        /// The CLI's own update command, when it has one that works however it was installed.
        /// Codex is updated the way it was installed (npm, Homebrew…), so it gets its install page.
        var updateArguments: [String]? { self == .claude ? ["update"] : nil }

        /// The help page that lists the options NotchApp uses, and those options. A version too old
        /// to list them all would fail every request with "unknown option".
        var helpArguments: [String] { self == .claude ? ["--help"] : ["exec", "--help"] }
        var requiredFlags: [String] {
            switch self {
            case .claude: ["--print", "--input-format", "--output-format", "--include-partial-messages", "--verbose", "--tools",
                           "--strict-mcp-config", "--setting-sources", "--disable-slash-commands", "--no-session-persistence",
                           "--system-prompt", "--model", "--effort"]
            case .codex: ["--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                          "--color", "--sandbox", "--cd", "--config", "--model", "--image"]
            }
        }

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
        /// Installed, but too old for the options NotchApp uses.
        case outdated
        /// The status check itself failed (timed out, unreadable answer). Requests still go
        /// through, so a real problem shows up as that request's error.
        case checkFailed

        /// Whether requests should go to the CLI.
        var usable: Bool { self == .ready || self == .checkFailed }
    }

    /// Posted on the main thread when a CLI's availability changes, so Settings and the Search
    /// tab update without waiting for someone to press Check again.
    static let availabilityChanged = Notification.Name("CLIAgent.availabilityChanged")

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

    /// Whether the CLI is installed, recent enough and signed in. Cached for a minute: Settings and
    /// the Search tab ask often, and each check starts a process. `refresh` skips the cache;
    /// `rescan` also looks for the CLI again and re-reads the Terminal setup (a CLI installed or
    /// moved since NotchApp opened).
    static func availability(_ tool: Tool, refresh: Bool = false, rescan: Bool = false) async -> Availability {
        let custom = await MainActor.run { AppSettings.shared.cliPaths[tool.providerRawValue] ?? "" }
        if !refresh, !rescan, let cached = await Locator.shared.cachedAvailability(tool) { return cached }
        if rescan { await Locator.shared.reloadShell() }
        guard let exe = await Locator.shared.executable(for: tool, custom: custom, refresh: rescan) else {
            await Locator.shared.store(.notInstalled, for: tool)
            return .notInstalled
        }
        let env = await Locator.shared.environment(for: exe)
        guard await Locator.shared.supportsRequiredFlags(tool, executable: exe, env: env) else {
            await Locator.shared.store(.outdated, for: tool)
            return .outdated
        }
        let result: Availability
        switch tool {
        case .claude:
            // `claude auth status --json` prints {"loggedIn": …, "apiProvider": …}; exit code 1 when
            // signed out. Company setups (Amazon Bedrock, Google Vertex…) sign in through their
            // cloud account rather than claude.ai, so they count as signed in.
            let r = await run(exe, ["auth", "status", "--json"], env: env, timeout: 15)
            // Just the JSON object: a warning may be printed around it.
            var json = ""
            if let start = r.out.firstIndex(of: "{"), let end = r.out.lastIndex(of: "}"), start < end { json = String(r.out[start...end]) }
            if let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               let loggedIn = obj["loggedIn"] as? Bool {
                let provider = obj["apiProvider"] as? String ?? "firstParty"
                result = loggedIn || provider != "firstParty" ? .ready : .signedOut
            } else {
                result = .checkFailed
            }
        case .codex:
            // `codex login status` exits 0 when signed in (ChatGPT or an API key saved in Codex),
            // and prints "Not logged in" with exit code 1 when not.
            let r = await run(exe, ["login", "status"], env: env, timeout: 15)
            if r.code == 0 { result = .ready }
            else if r.out.localizedCaseInsensitiveContains("not logged in") { result = .signedOut }
            else { result = .checkFailed }
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
    /// checks the result afterwards; it never handles the credentials. It watches for the sign-in
    /// to finish, so Settings and the Search tab turn ready by themselves.
    @MainActor static func openSignIn(_ tool: Tool) {
        openInTerminal(tool, arguments: tool.loginArguments, doing: "Signing in to \(tool.name)",
                       failed: "Sign-in didn't finish.", retry: "press Sign in again")
        watch(tool) { $0 == .ready }
    }

    /// Updates a CLI that's too old: Claude Code updates itself in Terminal; Codex's install page
    /// explains the update for however it was installed.
    @MainActor static func openUpdate(_ tool: Tool) {
        guard let arguments = tool.updateArguments else {
            NSWorkspace.shared.open(tool.installURL)
            watch(tool) { $0 != .outdated }
            return
        }
        openInTerminal(tool, arguments: arguments, doing: "Updating \(tool.name)",
                       failed: "The update didn't finish.", retry: "try Update again")
        watch(tool) { $0 != .outdated }
    }

    /// Runs one of the CLI's own commands in a Terminal window, with a line before and after
    /// saying what it's for and what to do next. Terminal is asked for by name, so the script
    /// isn't opened in an editor when .command files belong to another app. The script deletes
    /// itself as soon as it starts.
    @MainActor private static func openInTerminal(_ tool: Tool, arguments: [String], doing: String, failed: String, retry: String) {
        Task {
            let custom = AppSettings.shared.cliPaths[tool.providerRawValue] ?? ""
            let exe = await Locator.shared.executable(for: tool, custom: custom) ?? tool.command
            let command = ([exe] + arguments).map(shellQuoted).joined(separator: " ")
            let script = """
                #!/bin/zsh -l
                rm -f "$0"
                clear
                echo \(shellQuoted("\(doing) for NotchApp. A browser page may open; follow the steps there or below."))
                echo
                if \(command); then
                  echo
                  echo \(shellQuoted("Done. NotchApp picks this up by itself, so you can close this window."))
                else
                  echo
                  echo \(shellQuoted("\(failed) Close this window and \(retry) in NotchApp's Settings."))
                fi

                """
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("NotchApp-\(tool.command)-\(UUID().uuidString.prefix(8)).command")
            do {
                try script.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            } catch {
                DebugHooks.log("CLIAgent: couldn't write the Terminal script: \(error)")
                return
            }
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            if FileManager.default.fileExists(atPath: terminal.path) {
                NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { DebugHooks.log("CLIAgent: couldn't open Terminal: \(error)") }
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Re-checks every few seconds after a sign-in or update is started, until `done` holds or
    /// five minutes pass. Each change is posted (`availabilityChanged`), so the screens update.
    @MainActor private static var watchers: [Tool: Task<Void, Never>] = [:]

    @MainActor private static func watch(_ tool: Tool, until done: @escaping @Sendable (Availability) -> Bool) {
        watchers[tool]?.cancel()
        watchers[tool] = Task {
            for _ in 0..<100 {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                if done(await availability(tool, refresh: true)) { break }
            }
            if !Task.isCancelled { watchers[tool] = nil }
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
            case "assistant":
                // Claude Code's own name for what went wrong ("authentication_failed", "rate_limit"…).
                if let code = obj["error"] as? String { state.errorCode = code }
            case "result":
                let text = obj["result"] as? String ?? ""
                if obj["is_error"] as? Bool == true { state.error = text.isEmpty ? "Claude Code stopped with an error." : text }
                else { state.result = text }
            default: break
            }
        }
        if let error = state.error { throw await failure(error, code: state.errorCode, tool: .claude) }
        if state.refused { throw CLIError(message: "The model declined to answer that.") }
        let final = (state.text.isEmpty ? state.result ?? "" : state.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty, outcome.code != 0 {
            throw await failure(outcome.stderr.isEmpty ? "Claude Code exited with code \(outcome.code)." : outcome.stderr,
                                code: state.errorCode, tool: .claude)
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
        if let error = state.error { throw await failure(error, tool: .codex) }
        let final = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty {
            let why = state.lastNotice ?? (outcome.stderr.isEmpty ? "Codex exited with code \(outcome.code)." : outcome.stderr)
            throw await failure(why, tool: .codex)
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
        var errorCode: String?
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

    /// What a CLI's error comes down to, when it's one of the cases with a clear fix.
    enum Problem: Equatable {
        case signedOut, usageLimit, outdated
    }

    /// Reads a CLI's error. Matches whole phrases these CLIs actually print (checked against
    /// Claude Code 2.1 and Codex 0.157), not loose words like "login", so an unrelated error that
    /// happens to mention one isn't reported as a sign-in problem.
    static func problem(in raw: String, code: String? = nil) -> Problem? {
        let lower = raw.lowercased()
        // An old CLI rejecting an option NotchApp passes: Claude Code prints "error: unknown option
        // '--effort'", Codex "error: unexpected argument '--ignore-rules' found".
        if lower.contains("unknown option '--") || lower.contains("unexpected argument '--") { return .outdated }
        if code == "authentication_failed" { return .signedOut }
        if code == "rate_limit" { return .usageLimit }
        if ["not logged in", "please run /login", "please log in", "log in again", "sign in again",
            "invalid api key", "invalid x-api-key", "oauth token has expired", "could not be refreshed",
            "401 unauthorized", "missing bearer or basic authentication"].contains(where: lower.contains) {
            return .signedOut
        }
        if ["usage limit", "rate limit", "limit reached", "hit your limit", "429 too many requests",
            "quota exceeded", "insufficient_quota"].contains(where: lower.contains) {
            return .usageLimit
        }
        return nil
    }

    /// Turns the CLIs' errors into something to act on.
    static func friendly(_ raw: String, code: String? = nil, tool: Tool) -> String {
        let m = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch problem(in: m, code: code) {
        case .outdated?:
            return "This version of \(tool.name) is too old for NotchApp. Update it from Settings → Search."
        case .signedOut?:
            return "\(tool.name) isn't signed in. Sign in from Settings → Search."
        case .usageLimit?:
            return "Your \(tool.plan) plan's usage limit is reached for now. \(m)"
        case nil:
            return m.isEmpty ? "\(tool.name) stopped with an error." : "\(tool.name): \(m)"
        }
    }

    /// The error to show for a failed request. A sign-in or version problem also updates the
    /// saved status, so Settings and the Search tab show it straight away.
    private static func failure(_ raw: String, code: String? = nil, tool: Tool) async -> CLIError {
        switch problem(in: raw, code: code) {
        case .signedOut?: await Locator.shared.store(.signedOut, for: tool)
        case .outdated?: await Locator.shared.store(.outdated, for: tool)
        default: break
        }
        return CLIError(message: friendly(raw, code: code, tool: tool))
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
    /// Finds the CLI and the environment it needs. Apps opened from the Dock don't get the shell's
    /// setup, so an npm-installed CLI (which needs `node`) wouldn't run, and settings people keep in
    /// their shell profile (a company's Amazon Bedrock or Google Vertex setup, a proxy, a
    /// certificate) wouldn't apply. NotchApp reads the login shell's environment once and runs the
    /// CLI with it, the way it runs when typed in Terminal.
    actor Locator {
        static let shared = Locator()

        private var executables: [Tool: String] = [:]
        private var availability: [Tool: (value: Availability, at: Date)] = [:]
        private var shellEnvironment: [String: String]?
        /// Whether a given build of a CLI lists every option NotchApp uses, keyed by its path and
        /// modification date, so an update is noticed without re-reading the help on every check.
        private var flagSupport: [String: Bool] = [:]

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
            let shellPATH = await loginShellEnvironment()["PATH"] ?? ""
            candidates += shellPATH.split(separator: ":").map { "\($0)/\(tool.command)" }
            let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            executables[tool] = found
            return found
        }

        /// The environment for a CLI run: NotchApp's own, with the login shell's on top (its PATH
        /// plus the CLI's own folder first), and no API keys, so the CLI uses the plan it's signed in
        /// with rather than billing a key that happens to be set.
        func environment(for executable: String) async -> [String: String] {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in await loginShellEnvironment() where !Self.terminalOnlyKeys.contains(key) {
                env[key] = value
            }
            for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY",
                        // Set inside a Claude Code session; would make the CLI think it's nested.
                        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
                env.removeValue(forKey: key)
            }
            let dir = (executable as NSString).deletingLastPathComponent
            env["PATH"] = ([dir, env["PATH"] ?? "", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"])
                .filter { !$0.isEmpty }.joined(separator: ":")
            env["NO_COLOR"] = "1"
            env["TERM"] = "dumb"
            return env
        }

        /// Shell values that describe the Terminal session itself rather than the person's setup.
        private static let terminalOnlyKeys: Set<String> = [
            "_", "SHLVL", "PWD", "OLDPWD", "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
            "COLORTERM", "TMUX", "TMUX_PANE", "STY", "WINDOWID", "SSH_TTY",
        ]

        /// Whether this build of the CLI lists every option NotchApp passes it (`Tool.requiredFlags`).
        /// A help page that can't be read at all isn't held against it: the request's own error says more.
        func supportsRequiredFlags(_ tool: Tool, executable: String, env: [String: String]) async -> Bool {
            let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
            let modified = (try? FileManager.default.attributesOfItem(atPath: resolved)[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            let key = "\(resolved)@\(modified)"
            if let known = flagSupport[key] { return known }
            let r = await CLIAgent.run(executable, tool.helpArguments, env: env, timeout: 15)
            guard !r.out.isEmpty else { return true }
            let listed = Set(r.out.split(whereSeparator: { $0.isWhitespace || ",[]=()<>".contains($0) }).map(String.init))
            let supported = tool.requiredFlags.allSatisfy(listed.contains)
            flagSupport[key] = supported
            return supported
        }

        func cachedAvailability(_ tool: Tool) -> Availability? {
            guard let entry = availability[tool], Date().timeIntervalSince(entry.at) < 60 else { return nil }
            return entry.value
        }

        /// Saves a check's result and, when it changed, tells Settings and the Search tab.
        func store(_ value: Availability, for tool: Tool) {
            let changed = availability[tool]?.value != value
            availability[tool] = (value, Date())
            guard changed else { return }
            Task { @MainActor in
                NotificationCenter.default.post(name: CLIAgent.availabilityChanged, object: nil, userInfo: ["tool": tool.rawValue])
                AssistantStore.shared.refreshStatus()
            }
        }

        /// Looks again for the CLIs and re-reads the shell's environment, for a CLI installed or a
        /// shell profile changed since NotchApp opened.
        func reloadShell() {
            shellEnvironment = nil
            executables.removeAll()
        }

        /// The environment an interactive login shell sets up (PATH from nvm, Homebrew, Volta…, and
        /// whatever else the profile exports), read once and kept until `reloadShell`. Read with
        /// plain `env` between markers, so it works the same in zsh, bash and fish, and anything a
        /// profile prints around it is ignored.
        private func loginShellEnvironment() async -> [String: String] {
            if let shellEnvironment { return shellEnvironment }
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            let marker = "__NOTCHAPP_ENV__"
            let r = await CLIAgent.run(shell, ["-ilc", "printf '\(marker)'; /usr/bin/env; printf '\(marker)'"],
                                       env: ProcessInfo.processInfo.environment, timeout: 10)
            let parts = r.out.components(separatedBy: marker)
            let found = parts.count >= 3 ? Self.parseEnv(parts[1]) : [:]
            shellEnvironment = found
            return found
        }

        /// Reads `env` output: one NAME=value per line, where a line that doesn't start with a name
        /// continues the value above it (a value with a line break in it).
        static func parseEnv(_ text: String) -> [String: String] {
            var found: [String: String] = [:]
            var current: String?
            for line in text.components(separatedBy: "\n") {
                if let eq = line.firstIndex(of: "="), eq != line.startIndex,
                   line[..<eq].allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }) {
                    let key = String(line[..<eq])
                    found[key] = String(line[line.index(after: eq)...])
                    current = key
                } else if let key = current {
                    found[key, default: ""] += "\n" + line
                }
            }
            // The newline `env` ends with isn't part of the last value.
            if let key = current, let value = found[key], value.hasSuffix("\n") { found[key] = String(value.dropLast()) }
            return found
        }
    }
}

extension CLIAgent.Tool {
    var providerRawValue: String { self == .claude ? AIProvider.claudeCode.rawValue : AIProvider.codex.rawValue }
}
