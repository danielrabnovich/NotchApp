import AppKit
import ApplicationServices
import EventKit

/// Answers questions about NotchApp itself: "what can you do", "how do I keep screenshots",
/// "where's the setting for haptics", "what's new". It knows:
/// - the guide (Help/Guide.md), every Settings page, section and setting with its description, and
///   the changelog, all gathered at build time into Help.json by scripts/build-help.py;
/// - this Mac's setup right now: the keyboard shortcuts in use, which add-ons are on, the model and
///   the permissions.
/// The answer is written from those (with a model) and links to where each thing lives.
@MainActor
enum HelpBrain {
    struct Entry: Decodable, Sendable {
        let id: Int
        let kind: String        // guide, page, setting, permission, note, change, live
        let title: String
        let text: String
        var pane: String?
        var `where`: String?
        var date: String?
        var commit: String?
        var repo: String?
        /// The AppSettings switch this setting is (also its UserDefaults key), for its state now.
        var key: String?

        var isOnNow: Bool? { key.flatMap { UserDefaults.standard.object(forKey: $0) as? Bool } }
    }

    private struct File: Decodable { let entries: [Entry] }

    private static let base: [Entry] = {
        guard let url = Bundle.main.url(forResource: "Help", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.entries
    }()

    static var isAvailable: Bool { !base.isEmpty }

    // MARK: - Links

    /// notchapp://settings/<pane>, for the pane named by its case ("shelf") or title ("Shelf").
    static func settingsURL(_ pane: String) -> URL? {
        URL(string: "notchapp://settings/\(pane)")
    }

    static func pane(named name: String) -> SettingsPane? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return SettingsPane.allCases.first { String(describing: $0).lowercased() == n }
            ?? SettingsPane.allCases.first { $0.title.lowercased() == n || $0.rawValue.lowercased() == n }
            ?? SettingsPane.allCases.first { n.hasPrefix($0.title.lowercased()) || $0.title.lowercased().hasPrefix(n) }
    }

    /// Opens a notchapp:// link. Returns false for any other link, for the caller to open as usual.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard url.scheme == "notchapp" else { return false }
        switch url.host {
        case "settings":
            let name = url.pathComponents.dropFirst().first ?? ""
            SettingsWindowController.shared.show(pane: pane(named: name.removingPercentEncoding ?? name))
        default:
            SettingsWindowController.shared.show(pane: nil)
        }
        return true
    }

    /// "Settings → Shelf → Quick drops" in an answer, split out so it can be a link to that page.
    static func linkify(_ text: String) -> [(text: String, link: URL?)] {
        let pattern = #"Settings\s*(?:→|›|->|>)\s*[A-Z][\w&’' ]*?(?:\s*(?:→|›|->|>)\s*[A-Z][\w&’' ]*?)*(?=[.,;:!?)\]\n]|\s+(?:and|then|to|or|in|on|for|under|where|so|if|—|–)\b|$)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [(text, nil)] }
        var parts: [(String, URL?)] = []
        var last = text.startIndex
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let path = String(text[r])
            let segments = path.components(separatedBy: CharacterSet(charactersIn: "→›>")).map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-"))) }
            guard segments.count >= 2, let pane = pane(named: segments[1]), let url = settingsURL(String(describing: pane)) else { continue }
            if last < r.lowerBound { parts.append((String(text[last..<r.lowerBound]), nil)) }
            parts.append((path, url))
            last = r.upperBound
        }
        if last < text.endIndex { parts.append((String(text[last...]), nil)) }
        return parts.isEmpty ? [(text, nil)] : parts
    }

    /// A path that names a setting on the wrong page ("Settings → Shelf → Dynamic Glass", when Glass
    /// is in Appearance) is rewritten to where that setting really is. Models drift; links shouldn't.
    static func correctPaths(_ text: String) -> String {
        // Note numbers ([3]) point at nothing the user can see.
        var out = text.replacingOccurrences(of: #"\s?\[\d+\](\[\d+\])*"#, with: "", options: .regularExpression)
        for part in linkify(out) where part.link != nil {
            let segments = part.text.components(separatedBy: CharacterSet(charactersIn: "→›>"))
                .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-"))) }
            guard segments.count >= 3, let last = segments.last?.lowercased(), last.count >= 4,
                  let named = pane(named: segments[1]) else { continue }
            let settings = base.filter { ($0.kind == "setting" || $0.kind == "permission") && $0.title.count >= 4 }
            let match = settings.first { $0.title.lowercased() == last }
                ?? settings.first { last.contains($0.title.lowercased()) || $0.title.lowercased().contains(last) }
            guard let match, let pane = match.pane, let real = self.pane(named: pane), real != named,
                  let whereText = match.where else { continue }
            out = out.replacingOccurrences(of: part.text, with: "\(whereText) → \(match.title)")
        }
        return out
    }

    // MARK: - What this Mac has now

    private static func liveEntries() -> [Entry] {
        let s = AppSettings.shared
        var out: [Entry] = []
        let shortcuts = HotKeys.Action.allCases.map { action -> String in
            let combo = HotKeys.combo(for: action)?.display ?? ""
            return "\(action.title): \(combo.isEmpty ? "off" : combo)"
        }
        out.append(Entry(id: -1, kind: "live", title: "Your keyboard shortcuts right now",
                         text: (s.hotKeysEnabled ? "" : "Keyboard shortcuts are turned off. ") + shortcuts.joined(separator: "; ") + ".",
                         pane: "shortcuts"))

        let tabs: [(String, Bool)] = [("Home (music and calendar)", s.musicEnabled || s.calendarEnabled), ("Timer", s.timerEnabled),
                                      ("Mixer", s.mixerEnabled), ("Controls", s.controlsEnabled), ("Stats", s.statsEnabled),
                                      ("Tools", s.toolsEnabled), ("Agents", s.agentsEnabled)]
        let on = tabs.filter(\.1).map(\.0), off = tabs.filter { !$0.1 }.map(\.0)
        out.append(Entry(id: -2, kind: "live", title: "Your tabs right now",
                         text: "Search, Shelf and Tasks are always on. Also on: \(on.isEmpty ? "nothing else" : on.joined(separator: ", ")). "
                             + "Off (turn on in Settings → Add-ons): \(off.isEmpty ? "none" : off.joined(separator: ", ")).",
                         pane: "addOns"))

        let assistant = AssistantStore.shared
        let model: String
        switch s.aiProvider {
        case .apple: model = "Apple Intelligence (on this Mac)"
        case .local: model = "\(s.ollamaModel) through Ollama (on this Mac)"
        default: model = "a cloud model (\(s.aiProvider.rawValue))"
        }
        out.append(Entry(id: -3, kind: "live", title: "Your AI model right now",
                         text: "Search uses \(model). It is \(assistant.aiAvailable ? "ready" : "not ready: \(String(describing: assistant.status))"). Change it in Settings → Search → Intelligence.",
                         pane: "assistant"))

        let calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let permissions = [("Accessibility", AXIsProcessTrusted()), ("Screen Recording", CGPreflightScreenCaptureAccess()),
                           ("Calendars", calendar)]
        out.append(Entry(id: -4, kind: "live", title: "Your permissions right now",
                         text: permissions.map { "\($0.0): \($0.1 ? "allowed" : "not allowed")" }.joined(separator: "; ")
                             + ". See and grant them in Settings → Permissions.",
                         pane: "permissions"))

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        out.append(Entry(id: -5, kind: "live", title: "This copy of NotchApp", text: "Version \(version).", pane: "about"))
        return out
    }

    // MARK: - Finding what's relevant

    private static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "be", "to", "of", "in", "on", "for", "with", "and", "or", "it", "this", "that",
        "do", "does", "did", "can", "could", "how", "what", "where", "when", "why", "which", "who", "i", "me", "my", "you",
        "your", "we", "there", "here", "app", "notchapp", "notch", "use", "using", "get", "make", "want", "would", "should",
        "please", "find", "about", "from", "at", "by", "if", "so", "any", "some", "into", "up",
    ]

    /// Words people use for things, mapped to the words the app uses.
    private static let synonyms: [String: [String]] = [
        "hotkey": ["shortcut", "keyboard"], "keybind": ["shortcut", "keyboard"], "shortcut": ["keyboard"],
        "ai": ["model", "intelligence", "ollama"], "llm": ["model", "ollama"], "ollama": ["model"], "gpt": ["model", "cloud"],
        "claude": ["model", "cloud", "agent"], "openai": ["model", "cloud"], "delete": ["remove", "trash", "clear"],
        "disable": ["off", "turn"], "enable": ["on", "turn"], "screenshot": ["screen", "capture"], "clipboard": ["copy", "paste"],
        "paste": ["copy", "clipboard"], "airdrop": ["shelf"], "drag": ["drop", "shelf"], "music": ["playing", "media", "spotify"],
        "spotify": ["music", "playing"], "volume": ["sound", "hud"], "brightness": ["hud"], "permission": ["access", "allow"],
        "privacy": ["permission", "private"], "todo": ["task"], "reminder": ["task", "remind"], "meeting": ["calendar", "call"],
        "event": ["calendar"], "update": ["new", "changelog"], "changelog": ["new", "change"], "new": ["change"],
        "feature": ["can", "overview"], "capability": ["can", "overview"], "hover": ["open", "delay"], "open": ["opening"],
        "glance": ["live", "beside"], "battery": ["charging"], "weather": ["forecast"], "file": ["search", "finding"],
    ]

    private static func stem(_ w: String) -> String {
        var w = w
        for suffix in ["ing", "ies", "es", "ed", "s"] where w.count > suffix.count + 3 && w.hasSuffix(suffix) {
            w = String(w.dropLast(suffix.count)) + (suffix == "ies" ? "y" : "")
            break
        }
        return w
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 1 && !stopwords.contains($0) }.map(stem)
    }

    enum Intent { case overview, whatsNew, specific }

    static func intent(of q: String) -> Intent {
        let l = q.lowercased()
        if ["what's new", "whats new", "what is new", "changelog", "release notes", "recent changes", "what changed",
            "latest update", "new features", "latest features", "updates lately"].contains(where: l.contains) { return .whatsNew }
        if ["what can you do", "what can u do", "what do you do", "what can this", "capabilit", "all the features", "what features",
            "list of features", "what is notchapp", "what's notchapp", "get started", "getting started", "how does this work",
            "what does this app do", "what does notchapp do"].contains(where: l.contains) { return .overview }
        return .specific
    }

    /// The entries that best answer `q`, most relevant first.
    static func relevant(_ q: String, limit: Int = 12) -> [Entry] {
        let all = base + liveEntries()
        let intent = intent(of: q)
        var terms = words(q)
        for t in terms { terms += (synonyms[t] ?? []).map(stem) }
        let unique = Set(terms)

        // BM25 over title (counted three times) and text.
        let docs = all.map { e in words(e.title + " " + e.title + " " + e.title + " " + (e.where ?? "") + " " + e.text) }
        let avg = max(1, Double(docs.reduce(0) { $0 + $1.count }) / Double(max(1, docs.count)))
        var df: [String: Int] = [:]
        for d in docs { for w in Set(d) where unique.contains(w) { df[w, default: 0] += 1 } }
        let n = Double(docs.count)
        var scored: [(Entry, Double)] = []
        for (e, d) in zip(all, docs) {
            var score = 0.0
            var tf: [String: Int] = [:]
            for w in d where unique.contains(w) { tf[w, default: 0] += 1 }
            for (w, f) in tf {
                let docFreq: Double = Double(df[w] ?? 0)
                let ratio: Double = (n - docFreq + 0.5) / (docFreq + 0.5)
                let idf: Double = log(1.0 + ratio)
                let ff: Double = Double(f)
                let lengthNorm: Double = 0.25 + 0.75 * Double(d.count) / avg
                let weight: Double = (ff * 2.2) / (ff + 1.2 * lengthNorm)
                score += idf * weight
            }
            // Guide topics explain; settings say where; the changelog is for "what's new".
            switch e.kind {
            case "guide": score *= 1.35
            case "live": score *= 1.2
            case "change": score *= intent == .whatsNew ? 1.5 : 0.55
            default: break
            }
            if score > 0 { scored.append((e, score)) }
        }
        var picked = scored.sorted { $0.1 > $1.1 }.map(\.0)

        switch intent {
        case .overview:
            let overview = base.filter { $0.kind == "guide" && ($0.title.hasPrefix("What NotchApp is") || $0.title.hasPrefix("What it can do")) }
            let pages = base.filter { $0.kind == "page" }
            picked = overview + Array(pages.prefix(8)) + liveEntries().filter { $0.title.hasPrefix("Your tabs") } + picked
        case .whatsNew:
            let recent = base.filter { $0.kind == "change" }.prefix(10)
            picked = Array(recent) + picked
        case .specific:
            break
        }
        var seen = Set<String>()
        return Array(picked.filter { seen.insert("\($0.kind)|\($0.id)|\($0.title)").inserted }.prefix(limit))
    }

    // MARK: - Answering

    static func answer(_ question: String, useAI: Bool,
                       progress: @escaping @Sendable (String) async -> Void,
                       partial: @escaping @Sendable (String, [WebSource]) async -> Void) async throws -> (answer: String, sources: [WebSource]) {
        await progress("Reading the guide")
        let entries = relevant(question)
        guard !entries.isEmpty else {
            return ("I couldn't find that in NotchApp's guide or settings. Type “/” to see every command, or look through Settings.", [])
        }
        guard useAI else {
            // No model: the best topic, as written, and where to find more.
            let top = entries.first!
            return ("\(top.title)\n\(top.text.prefix(600))", [])
        }

        var context = ""
        for (i, e) in entries.enumerated() {
            var head = "[\(i + 1)] "
            switch e.kind {
            case "change": head += "Changelog \(e.date ?? ""): \(e.title)"
            case "setting", "permission":
                head += "Setting “\(e.title)” in \(e.where ?? "Settings")"
                if let on = e.isOnNow { head += " (currently \(on ? "on" : "off"))" }
            case "page", "note": head += e.title
            case "live": head += e.title
            default: head += "Guide: \(e.title)"
            }
            context += head + "\n" + String(e.text.prefix(e.kind == "guide" ? 1400 : 600)) + "\n\n"
        }
        let system = """
        You are NotchApp's built-in help. NotchApp is the Mac app the user is typing into: it lives in the MacBook notch. \
        Answer their question about NotchApp using ONLY the numbered notes below (the guide, the Settings window, this Mac's \
        current setup, and the changelog). Be friendly and practical.
        - Lead with the direct answer, then the steps as short "• " bullets when there are steps.
        - Say exactly where things are, written as a path like Settings → Shelf → Quick drops; the app turns these \
        into links. Copy paths from the notes exactly (a page's title, or the "in Settings → …" of a setting) and \
        never put a setting on a page the notes don't. Changelog notes have no path: only give one if another note does.
        - Pick settings by their description, not just their name, and say whether each is on or off right now \
        when the notes say so ("it's on at the moment"). Mention keyboard shortcuts from the notes when they help.
        - The changelog isn't shown in Settings; don't send people there for it.
        - "What can you do" questions: a one-line summary, then up to 8 bullets of the main things, each with where to turn it on.
        - "What's new" questions: the most recent changes first, by date, in plain words.
        - Don't cite note numbers. Plain text: no markdown headings, no bold, no links in brackets.
        - If the notes don't cover it, say so plainly and suggest typing “/” for every command or opening Settings. Never invent features or settings.
        Under 170 words.
        """
        let text = try await OllamaClient.chatStream(system: system, user: "Question: \(question)\n\nNotes:\n\(context)") { soFar in
            let fixed = await MainActor.run { correctPaths(soFar) }
            await partial(fixed, [])
        }
        return (correctPaths(text), [])
    }
}
