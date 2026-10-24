import AppKit
import Darwin

/// The `notch` command's way in, and through it coding agents' (Claude Code's hooks run `notch
/// hook`, MCP clients run `notch mcp`): a Unix socket in NotchApp's Application Support folder
/// that only this user can open, checked again per connection by the peer's user ID. One JSON
/// request per connection, one JSON reply.
final class CommandBridge: @unchecked Sendable {
    static let shared = CommandBridge()

    static let socketURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchApp/notch.sock")

    /// Where the command lives: inside the app, beside NotchApp itself.
    static var commandURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notch") }

    private let queue = DispatchQueue(label: "com.notchapp.command-bridge")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    func start() {
        queue.async { self.listen() }
    }

    // MARK: - On the PATH

    /// Where the link to `notch` goes: Homebrew's bin (on everyone's PATH who has Homebrew), the
    /// classic /usr/local/bin if this user can write it, else ~/.local/bin.
    private static var linkFolders: [URL] {
        ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")]
    }

    /// The `notch` link already made to this copy of NotchApp, if there is one. A link to another
    /// copy (a test build, one since moved) doesn't count: installing again points it here.
    static var installedLink: URL? {
        linkFolders.map { $0.appendingPathComponent("notch") }.first { link in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == commandURL.path
        }
    }

    /// Links `notch` into a folder on the PATH (replacing a link to another copy of NotchApp, never anything else).
    static func installLink() throws -> URL {
        let fm = FileManager.default
        // Where a link to some copy of NotchApp already is, so there's never two; else the first that can be written.
        let ours = linkFolders.first { ((try? fm.destinationOfSymbolicLink(atPath: $0.appendingPathComponent("notch").path)) ?? "").hasSuffix(".app/Contents/MacOS/notch") }
        let folder = ours ?? linkFolders.first { fm.isWritableFile(atPath: $0.path) } ?? linkFolders.last!
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("notch")
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            guard existing.hasSuffix(".app/Contents/MacOS/notch") else { throw LinkError.taken(link.path) }
            try fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            throw LinkError.taken(link.path)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: commandURL)
        return link
    }

    enum LinkError: LocalizedError {
        case taken(String)
        var errorDescription: String? {
            switch self {
            case .taken(let path): "Something else is already called notch at \(path)."
            }
        }
    }

    /// Adds NotchApp's MCP server to Claude Code, for all projects (run in a terminal).
    static var mcpSetupCommand: String {
        "claude mcp add --scope user notchapp -- '\(commandURL.path)' mcp"
    }

    /// Takes the socket away on quit, so `notch` says NotchApp isn't running rather than hanging.
    func stop() {
        guard listener >= 0 else { return }
        close(listener)
        unlink(Self.socketURL.path)
    }

    private func listen() {
        let path = Self.socketURL.path
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.socketURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        // Owner-only from the moment it exists.
        let mask = umask(0o077)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(mask)
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            DebugHooks.log("BRIDGE couldn't listen: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        self.source = source
    }

    private func acceptAll() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            // Accepted sockets inherit the listener's non-blocking mode; these are read plainly.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { self.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while data.count < 256_000 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break }
        }
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            Self.write(["error": "not a request"], to: fd)
            return
        }
        let reply: @Sendable ([String: Any]) -> Void = { body in
            DispatchQueue.global(qos: .userInitiated).async { Self.write(body, to: fd) }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { CommandHandler.handle(request, reply: reply) }
        }
    }

    private static func write(_ body: [String: Any], to fd: Int32) {
        defer { close(fd) }
        guard var data = try? JSONSerialization.data(withJSONObject: body) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}

/// What each request does: Banners, rings, the Shelf, questions, and agents' hook events.
@MainActor
enum CommandHandler {
    /// Who sent it: the process that ran `notch` (a shell, or the agent behind `notch mcp`) and its folder.
    struct Source {
        let pid: pid_t?
        let cwd: String?

        init(_ value: Any?) {
            let dict = value as? [String: Any] ?? [:]
            pid = (dict["pid"] as? NSNumber).map { pid_t(truncating: $0) }.flatMap { $0 > 1 ? $0 : nil }
            cwd = dict["cwd"] as? String
        }

        var project: String? { cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0 == "/" || $0.isEmpty ? nil : $0 } }
        var tool: AgentMonitor.Tool? { pid.flatMap(AgentMonitor.tool(owning:)) }

        /// "Claude Code · NotchApp" for an agent, the project for a shell.
        func label(agent: Bool) -> String {
            let who = agent ? (tool?.name ?? "An agent") : nil
            return [who, project].compactMap { $0 }.joined(separator: " · ")
        }

        @MainActor func focus() { if let pid { AgentMonitor.shared.focus(pid: pid) } }
    }

    static func handle(_ request: [String: Any], reply: @escaping @Sendable ([String: Any]) -> Void) {
        let source = Source(request["source"])
        let agent = request["agent"] as? Bool == true
        switch request["cmd"] as? String {
        case "ping":
            reply(["ok": true, "version": AppUpdater.currentVersion])
        case "banner":
            reply(banner(request, source: source, agent: agent))
        case "progress":
            reply(progress(request, source: source, agent: agent))
        case "finished":
            finished(request, source: source)
            reply(["ok": true])
        case "shelf":
            let urls = (request["paths"] as? [String] ?? []).prefix(50).map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return reply(["error": "none of those files exist"]) }
            ShelfStore.shared.add(Array(urls))
            reply(["ok": true, "added": urls.count])
        case "ask":
            ask(request, source: source, agent: agent, reply: reply)
        case "hook":
            AgentHooks.shared.receive(request["event"] as? [String: Any] ?? [:])
            reply(["ok": true])
        default:
            reply(["error": "unknown command"])
        }
    }

    // MARK: - Banners

    /// Recent Banners by sender, so a looping script or a chatty agent can't fill the notch.
    private static var recent: [pid_t: [Date]] = [:]

    private static func allowBanner(from pid: pid_t?) -> Bool {
        let key = pid ?? 0
        let now = Date()
        let times = (recent[key] ?? []).filter { now.timeIntervalSince($0) < 60 }
        recent = recent.filter { !$0.value.isEmpty && $0.key != key }
        guard times.count < 6 else { recent[key] = times; return false }
        recent[key] = times + [now]
        return true
    }

    private static func banner(_ r: [String: Any], source: Source, agent: Bool) -> [String: Any] {
        let title = clip(r["title"] as? String, 70)
        guard !title.isEmpty else { return ["error": "a Banner needs a title"] }
        guard allowBanner(from: source.pid) else { return ["error": "too many Banners in the last minute; try again shortly"] }
        let given = clip(r["detail"] as? String, 120)
        let detail = agent ? [given, source.label(agent: true)].filter { !$0.isEmpty }.joined(separator: " · ") : given
        let fallback = agent ? "sparkles.rectangle.stack.fill" : "terminal.fill"
        let symbol = (r["symbol"] as? String).flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil } ?? fallback
        let tone: NoticeTone = switch r["tone"] as? String {
        case "success": .success
        case "warning": .warning
        default: .info
        }
        ActivityCenter.shared.show(.notice(title: title, detail: detail, icon: symbol, tone: tone), for: 5) { source.focus() }
        return ["ok": true]
    }

    // MARK: - Rings

    private static func progress(_ r: [String: Any], source: Source, agent: Bool) -> [String: Any] {
        guard let raw = r["id"] as? String, !raw.isEmpty, raw.count < 80 else { return ["error": "a ring needs an id"] }
        // Kept apart from NotchApp's own (downloads, conversions).
        let id = "ext:" + raw
        if r["done"] as? Bool == true {
            ProgressCenter.shared.removeExternal(id)
            return ["ok": true]
        }
        let fraction = (r["fraction"] as? NSNumber).map { min(max($0.doubleValue, 0), 1) }
        let owner = (r["owner"] as? NSNumber).map { pid_t(truncating: $0) }
        let item = ProgressCenter.Item(id: id, title: clip(r["title"] as? String, 60).nilIfEmpty ?? "Working", fraction: fraction,
                                       bundlePath: nil, target: nil, label: (r["label"] as? String).map { clip($0, 8) },
                                       detail: source.label(agent: agent).nilIfEmpty, focusPID: source.pid)
        ProgressCenter.shared.setExternal(item, owner: owner)
        return ["ok": true]
    }

    /// `notch run` is done: its ring goes, and a Banner says how it went (a click goes back to its terminal).
    private static func finished(_ r: [String: Any], source: Source) {
        if let raw = r["id"] as? String { ProgressCenter.shared.removeExternal("ext:" + raw) }
        let title = clip(r["title"] as? String, 40).nilIfEmpty ?? "Command"
        let status = (r["status"] as? NSNumber)?.intValue ?? 0
        let took = duration((r["seconds"] as? NSNumber)?.doubleValue ?? 0)
        let outcome = status == 0 ? "Done in \(took)" : status == 130 ? "Stopped after \(took)" : "Failed (exit \(status)) after \(took)"
        let detail = [outcome, source.project].compactMap { $0 }.joined(separator: " · ")
        ActivityCenter.shared.show(.notice(title: title, detail: detail, icon: "terminal.fill", tone: status == 0 ? .success : .warning),
                                   for: 6) { source.focus() }
    }

    // MARK: - Questions

    /// Words that make a question a request for permission, which the notch never answers: an
    /// agent's tools are allowed or denied in its own terminal.
    private static let permissionWords = try! NSRegularExpression(
        pattern: #"\b(permission|permit|approve|approval|authori[sz]e|grant|allow (me|it|you|this)|may i|(ok|okay) to (run|delete|remove|push|deploy|execute|install)|can i (run|delete|remove|push|deploy|execute|install)|should i (run|execute))\b"#,
        options: [.caseInsensitive])
    private static let permissionChoices: Set<String> = ["allow", "deny", "approve", "reject", "allow once", "always allow", "don't allow"]

    private static func ask(_ r: [String: Any], source: Source, agent: Bool, reply: @escaping @Sendable ([String: Any]) -> Void) {
        let question = clip(r["question"] as? String, 140)
        var seen = Set<String>()
        let choices = (r["choices"] as? [String] ?? []).map { clip($0, 24) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard !question.isEmpty else { return reply(["error": "a question is needed"]) }
        guard (2...3).contains(choices.count) else { return reply(["error": "give 2 or 3 different choices"]) }
        let text = ([question] + choices).joined(separator: " ")
        if permissionWords.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            || choices.contains(where: { permissionChoices.contains($0.lowercased()) }) {
            return reply(["error": "The notch doesn't answer permission questions: tool and command permissions are answered in the terminal. Ask for a choice instead, or ask in the terminal."])
        }
        let timeout = min(max((r["timeout"] as? NSNumber)?.doubleValue ?? 120, 5), 600)

        let answer = Answer(reply)
        let prompt = Prompt(icon: "questionmark.bubble.fill", tint: .systemPurple, title: question,
                            detail: source.label(agent: agent).nilIfEmpty ?? "From the terminal",
                            actions: choices.enumerated().map { i, choice in
                                .init(title: choice, primary: i == 0) { answer.give(["choice": choice]) }
                            })
        NotchPresenter.shared.offer(prompt, peekFor: 8)
        let deadline = Date().addingTimeInterval(timeout)
        // Answered, put away, or out of time: whichever comes first replies.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                if answer.given { return timer.invalidate() }
                let presenter = NotchPresenter.shared
                var showing = false
                if case .prompt(let p)? = presenter.primary?.overlay, p.id == prompt.id { showing = true }
                let pending = presenter.pendingPrompt?.id == prompt.id && presenter.hasRecentPrompt
                if !showing, !pending {
                    answer.give(["outcome": "The user put the question away without choosing."])
                } else if Date() > deadline {
                    presenter.withdraw(prompt.id)
                    answer.give(["outcome": "No answer within \(Int(timeout)) seconds."])
                }
                if answer.given { timer.invalidate() }
            }
        }
    }

    /// Replies once, however many ways the question ends.
    @MainActor private final class Answer {
        private let reply: @Sendable ([String: Any]) -> Void
        private(set) var given = false
        init(_ reply: @escaping @Sendable ([String: Any]) -> Void) { self.reply = reply }
        func give(_ body: [String: Any]) {
            guard !given else { return }
            given = true
            reply(body)
        }
    }

    // MARK: -

    private static func clip(_ s: String?, _ n: Int) -> String {
        let line = (s ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > n ? String(line.prefix(n - 1)) + "…" : line
    }

    /// "12s", "4m 12s", "1h 5m".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
