import AppKit

/// "Do it in this app": an instruction typed into the bar ("export this as a PDF", "mark all as
/// read", "zoom in") carried out in the app in front. The model doesn't operate the app; it picks,
/// by number, from what the app can really do right now: its enabled menu items, the notch's
/// actions for it, and window layouts. A sure, harmless pick just runs; anything that deletes,
/// closes or quits, or a pick it isn't sure of, is shown for a click first.
@MainActor
enum AppDo {
    struct Choice: Equatable {
        let app: String
        /// Best first, then up to two alternatives.
        let picks: [Command]
        /// The model was sure of the first one.
        let sure: Bool
    }

    /// The right menu item exists but can't be used right now (Zoom In with no page open).
    static func unavailable(_ command: Command) -> Bool {
        if case .menuItem(let ref) = command.action { return !ref.item.enabled }
        return false
    }

    struct Failure: LocalizedError {
        let message: String
        /// Nothing in the app's menus matched: Search tries the request the usual way instead.
        var noMatch = false
        var errorDescription: String? { message }
    }

    /// Typed text that reads as an instruction for an app rather than a search: it starts with a verb.
    /// "Find a photo of…", "open my resume", "show the pdf from Sarah" are searches of the Mac, not
    /// menu commands, so they stay with Search.
    static func looksLikeInstruction(_ q: String) -> Bool {
        let lower = q.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard words.count >= 2, let first = words.first, verbs.contains(first) else { return false }
        for word in words where searchWords.contains(word) { return false }
        if first == "find" {
            let inApp: [String] = ["find and replace", "find next", "find previous", "find in"]
            for phrase in inApp where lower.hasPrefix(phrase) { return true }
            return false
        }
        return true
    }

    private static let searchWords: Set<String> = [
        "my", "named", "called", "photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "file", "files",
        "document", "documents", "doc", "docs", "pdf", "screenshot", "screenshots", "video", "videos", "folder", "resume",
        "slides", "deck", "spreadsheet", "essay", "notes", "receipt", "invoice",
    ]

    private static let verbs: Set<String> = [
        "export", "save", "print", "share", "open", "close", "new", "make", "turn", "switch", "show", "hide", "toggle",
        "zoom", "go", "move", "mark", "archive", "duplicate", "rename", "copy", "undo", "redo", "reload", "refresh",
        "find", "select", "sort", "add", "delete", "remove", "mute", "unmute", "play", "pause", "bookmark", "pin", "unpin",
        "minimize", "maximize", "enter", "exit", "start", "stop", "send", "reply", "forward", "convert", "compress",
        "render", "bounce", "rotate", "crop", "flip", "resize", "insert", "format", "bold", "italicize", "underline",
        "center", "align", "split", "merge", "clear", "reset", "sync", "enable", "disable", "use", "change", "set",
        "snap", "tile", "put", "group", "ungroup", "lock", "unlock", "collapse", "expand", "fold", "unfold", "run",
        "build", "join", "leave", "invite", "favorite", "favourite", "like", "flag", "star", "filter", "view", "fill",
    ]

    /// Finds what does `request` in the app in front.
    static func choose(_ request: String) async throws -> Choice {
        guard let app = FrontmostTracker.shared.userApp else {
            throw Failure(message: "There's no app in front to do that in.")
        }
        let name = app.localizedName ?? "the app"
        let candidates = await self.candidates(for: app, request: request)
        guard !candidates.isEmpty else { throw Failure(message: "Couldn't read \(name)'s menus. Is NotchApp allowed under Accessibility?") }

        let list = candidates.enumerated().map { "\($0.offset + 1). \($0.element.line)" }.joined(separator: "\n")
        let window = AppActions.shared.context.flatMap { $0.pid == app.processIdentifier ? $0.windowTitle : nil }
        let system = """
        You operate the Mac app "\(name)" for the user. The list is everything you can do in it right now: its \
        menu items (Menu › Item, with the shortcut), the notch's actions for it, and window layouts. Menu items \
        marked (unavailable now) exist but can't be used at the moment: if one is what they asked for, pick it \
        anyway rather than something that only sounds similar.
        Pick what does what the user asks. Reply with JSON only: {"picks": [numbers], "sure": true or false}
        - "picks": the best match first, then up to two alternatives. Only numbers from the list.
        - "sure": true only when the first pick plainly does what they asked.
        - Nothing in the list does it: {"picks": [], "sure": false}.
        """
        let user = "Request: \(request)\n" + (window.map { "Window: \($0)\n" } ?? "") + "\n" + list
        let reply = try await OllamaClient.chat(system: system, user: user, json: true)
        let obj = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
        let numbers = (obj["picks"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue ?? Int("\($0)") }
        var seen = Set<Int>()
        let all = numbers.filter { candidates.indices.contains($0 - 1) && seen.insert($0).inserted }.map { candidates[$0 - 1].command }
        // The first pick decides; alternatives that can't run now aren't worth showing.
        let picks = Array(([all.first].compactMap { $0 } + all.dropFirst().filter { !unavailable($0) }).prefix(3))
        DebugHooks.log("AppDo [\(name)] \(request) → \(picks.map(\.title)) sure=\(obj["sure"] ?? "?") of \(candidates.count)")
        guard let first = picks.first else {
            throw Failure(message: "Couldn't find a way to do that in \(name). Try the words its menus use.", noMatch: true)
        }
        if unavailable(first) {
            throw Failure(message: "“\(first.title)” is in \(name)'s menus, but not available right now. It may need something open or selected first.")
        }
        return Choice(app: name, picks: Array(picks), sure: (obj["sure"] as? Bool) ?? false)
    }

    /// Something to check with the user first, however sure the model is.
    static func isRisky(_ command: Command) -> Bool {
        let words = (command.title + " " + (command.subtitle ?? "")).lowercased()
        return ["delete", "remove", "quit", "close", "erase", "empty", "trash", "discard", "revert", "sign out", "log out",
                "clear", "reset", "uninstall", "force", "restart", "shut down", "replace all", "overwrite", "leave", "end "]
            .contains { words.contains($0) }
    }

    // MARK: - What the app can do

    private struct Candidate {
        let command: Command
        /// How the model sees it.
        let line: String
    }

    private static let limit = 450

    /// The app's actions, its menus read fresh (what's enabled changes with the selection), and window
    /// layouts. Menus that match the request's words come first, so the cut never drops the answer.
    private static func candidates(for app: NSRunningApplication, request: String) async -> [Candidate] {
        var out: [Candidate] = []
        let actions = AppActions.shared
        if actions.context?.pid == app.processIdentifier {
            for command in actions.items {
                if case .template = command.action { continue }
                if case .menuItem = command.action { continue } // listed with the menus below
                out.append(Candidate(command: command, line: "Action: \(command.title)"))
            }
        }
        let menus = await MenuSearch.shared.readNow(pid: app.processIdentifier, appName: app.localizedName ?? "App")
        let words = Set(request.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 })
        let ranked = menus.enumerated().sorted { a, b in
            let sa = words.filter { a.element.item.searchText.contains($0) }.count
            let sb = words.filter { b.element.item.searchText.contains($0) }.count
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
        for ref in ranked.prefix(limit - out.count - WindowManager.Action.allCases.count) {
            let path = (ref.item.path + [ref.item.title]).joined(separator: " › ")
            out.append(Candidate(command: Command(action: .menuItem(ref), title: ref.item.title.replacingOccurrences(of: "…", with: ""),
                                                  subtitle: path + (ref.item.shortcut.map { "  \($0)" } ?? ""),
                                                  icon: "filemenu.and.selection", verb: "Run"),
                                 line: "Menu: \(path)" + (ref.item.shortcut.map { "  \($0)" } ?? "") + (ref.item.enabled ? "" : "  (unavailable now)")))
        }
        for layout in WindowManager.Action.allCases {
            out.append(Candidate(command: Command(action: .window(layout), title: "Window: \(layout.title)", subtitle: "The window in front",
                                                  icon: "macwindow", verb: "Move"),
                                 line: "Window layout: \(layout.title)"))
        }
        return out
    }
}
