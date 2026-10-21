import AppKit
#if canImport(FoundationModels)
@_weakLinked import FoundationModels
#endif

/// What Recall found for a question, as the Search tab shows it.
struct RecallAnswer: Equatable, Sendable {
    let filter: RecallSearch.Filter
    let hits: [RecallSearch.Hit]
    /// A sentence answering the question from the hits' text, when a model on this Mac wrote one.
    var sentence: String?

    static func == (a: RecallAnswer, b: RecallAnswer) -> Bool {
        a.hits.map(\.id) == b.hits.map(\.id) && a.sentence == b.sentence && a.filter == b.filter
    }
}

/// Finds things in Recall: reads a question ("what was that error in Terminal yesterday") into
/// a time range, an app and words, then ranks captures by the words (FTS5's BM25), how they
/// looked (MobileCLIP, when it's installed) and how recent they are. Text in, text out: no model
/// ever looks at the pictures.
enum RecallSearch {
    struct Filter: Equatable, Sendable, CustomStringConvertible {
        var from: Date?
        var to: Date?
        /// What the time words were ("yesterday"), for the results' header.
        var when: String?
        var apps: [String] = []
        var bundleIDs: [String] = []
        var keywords: [String] = []
        /// How it looked ("a dark dashboard with a red chart"), for MobileCLIP.
        var looks: String?
        var byModel = false

        var description: String {
            let f = { (d: Date?) in d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "-" }
            return "when=\(when ?? "-") [\(f(from)) → \(f(to))] apps=\(apps) bundles=\(bundleIDs) keywords=\(keywords) looks=\(looks ?? "-") model=\(byModel)"
        }
    }

    struct Hit: Identifiable, Equatable, Sendable {
        let id: Int64
        let time: Date
        let bundleID: String?
        let appName: String?
        let title: String?
        let location: String?
        let snippet: String
        let thumbnail: URL?
        let score: Double

        static func == (a: Hit, b: Hit) -> Bool { a.id == b.id }
    }

    // MARK: - Routing

    /// Plainly a question about something seen before, so Search asks Recall instead of the web or files.
    @MainActor static func looksLikeRecall(_ query: String) -> Bool {
        guard AppSettings.shared.recall else { return false }
        let l = query.lowercased().replacingOccurrences(of: "’", with: "'")
        if l.hasPrefix("recall ") { return true }
        let phrases = ["when did i see", "where did i see", "did i see", "i saw", "have i seen", "i've seen", "i was looking at",
                       "i looked at", "i was reading", "i was on", "was on my screen", "on my screen earlier", "i had open",
                       "i had up", "what was that", "that thing i", "the one i saw"]
        let hasPhrase = phrases.contains { l.range(of: "\\b\(NSRegularExpression.escapedPattern(for: $0))\\b", options: .regularExpression) != nil }
        // "What was the score yesterday" is for the web: a seeing phrase, or "what was that…" with a
        // time or an app Recall knows.
        let seeing = ["see", "saw", "seen", "looked", "looking", "reading", "open", "screen", "had"]
        let words = Set(l.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init))
        if hasPhrase, !words.isDisjoint(with: seeing) { return true }
        let timed = resolveTime(l) != nil
        let inApp = !apps(in: l).bundleIDs.isEmpty
        if hasPhrase, timed || inApp { return true }
        // "yesterday in Slack…", "earlier in Terminal": a time and an app Recall has seen.
        return timed && inApp && l.range(of: #"\b(in|on|from)\s"#, options: .regularExpression) != nil
    }

    // MARK: - Reading the question

    /// The filter for a question: Apple's on-device model fills it in where there is one, else
    /// (and for anything it leaves out) the words are read directly.
    static func parse(_ raw: String) async -> Filter {
        var query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.lowercased().hasPrefix("recall ") { query = String(query.dropFirst(7)) }
        let text = query
        let heuristic = await MainActor.run { parseWithoutModel(text) }
        let started = Date()
        guard AppleModel.isAvailable, let guided = await parseWithModel(query) else { return heuristic }
        DebugHooks.log("Recall: model read the question in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        // Times and apps are resolved from the words either way. The model only fills a gap, and
        // only for what was actually said: asked for "when", it tends to answer "today" regardless.
        var filter = guided
        let lower = query.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        if heuristic.from != nil || words.isDisjoint(with: timeWords.subtracting(["an", "this", "other", "few", "couple"])) {
            filter.from = heuristic.from; filter.to = heuristic.to; filter.when = heuristic.when
        }
        if !heuristic.bundleIDs.isEmpty { filter.apps = heuristic.apps; filter.bundleIDs = heuristic.bundleIDs }
        let appWords = Set(heuristic.apps.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        filter.keywords = filter.keywords.filter { !appWords.contains($0) && !timeWords.contains($0) }
        if filter.keywords.isEmpty { filter.keywords = heuristic.keywords }
        // A description of how it looked only when the question gave one.
        let appearance = ["looked like", "look like", "looks like", "colou", "color", "dark", "light", "picture", "photo", "image",
                          "chart", "graph", "diagram", "red", "blue", "green", "yellow", "orange", "purple", "black", "white"]
        if !appearance.contains(where: lower.contains) { filter.looks = nil }
        return filter
    }

    /// Times, apps and keywords straight from the words.
    @MainActor static func parseWithoutModel(_ query: String) -> Filter {
        let lower = query.lowercased().replacingOccurrences(of: "’", with: "'")
        var filter = Filter()
        var rest = lower
        if let time = resolveTime(lower) {
            (filter.from, filter.to, filter.when) = (time.from, time.to, time.label)
            // "2 days ago": the 2 isn't something to look for.
            rest = rest.replacingOccurrences(of: time.label, with: " ")
        }
        let found = apps(in: lower)
        filter.apps = found.names
        filter.bundleIDs = found.bundleIDs
        let appWords = Set(found.matchedWords)
        let ordered = rest.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "-" && $0 != "_" }).map(String.init)
        var seen = Set<String>()
        filter.keywords = ordered.filter { word in
            let w = word.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
            return (w.count >= 2 || w.allSatisfy(\.isNumber)) && !filler.contains(w) && !timeWords.contains(w) && !appWords.contains(w)
                && seen.insert(w).inserted
        }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-_")) }
        return filter
    }

    private static let filler: Set<String> = [
        "recall", "when", "where", "what", "which", "who", "how", "did", "do", "does", "i", "i'm", "i've", "me", "my", "was",
        "were", "is", "are", "be", "been", "the", "a", "an", "that", "this", "those", "these", "it", "its", "there", "then",
        "see", "saw", "seen", "look", "looked", "looking", "read", "reading", "open", "opened", "had", "have", "up", "on",
        "in", "at", "from", "of", "for", "to", "about", "with", "and", "or", "again", "thing", "stuff", "something",
        "screen", "window", "show", "find", "remind", "one", "some", "back", "ago", "around", "last", "past", "earlier",
        "before", "just", "while", "find", "again", "was", "can", "you", "tell", "please",
    ]

    private static let timeWords: Set<String> = [
        "today", "yesterday", "tonight", "morning", "afternoon", "evening", "night", "week", "month", "hour", "hours",
        "minute", "minutes", "day", "days", "weekend", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "an", "couple", "few", "this", "other",
    ]

    /// "yesterday", "this morning", "on tuesday", "2 hours ago", "last week": a range, and how it was put.
    static func resolveTime(_ lower: String, now: Date = Date()) -> (from: Date, to: Date, label: String)? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
        func at(_ base: Date, _ hour: Int) -> Date { cal.date(byAdding: .hour, value: hour, to: base)! }
        func has(_ pattern: String) -> Bool { lower.range(of: "\\b\(pattern)\\b", options: .regularExpression) != nil }

        // "3 hours ago", "20 minutes ago", "2 days ago": around then.
        if let m = lower.range(of: #"\b(\d+|an?|a couple of|a few)\s+(minute|minutes|min|mins|hour|hours|hr|hrs|day|days)\s+ago\b"#,
                               options: .regularExpression) {
            let parts = lower[m].split(separator: " ")
            let n: Int = Int(parts[0]) ?? (lower[m].contains("couple") ? 2 : lower[m].contains("few") ? 3 : 1)
            let unit = String(parts[parts.count - 2])
            let seconds: TimeInterval = unit.hasPrefix("m") ? 60 : unit.hasPrefix("h") ? 3600 : 86_400
            let center = now.addingTimeInterval(-Double(n) * seconds)
            let spread = max(seconds * Double(n) * 0.5, unit.hasPrefix("m") ? 600 : 1800)
            return (center.addingTimeInterval(-spread), min(center.addingTimeInterval(spread), now), String(lower[m]))
        }
        if has("(last|past) (hour|hr)") || has("an hour ago") { return (now.addingTimeInterval(-3600), now, "in the last hour") }
        if has("(last|past) (\\d+) hours") , let m = lower.range(of: #"\d+(?= hours)"#, options: .regularExpression), let n = Int(lower[m]) {
            return (now.addingTimeInterval(-Double(n) * 3600), now, "in the last \(n) hours")
        }
        if has("last night") { return (at(day(-1), 18), at(today, 4), "last night") }
        if has("yesterday morning") { return (at(day(-1), 5), at(day(-1), 12), "yesterday morning") }
        if has("yesterday afternoon") { return (at(day(-1), 12), at(day(-1), 18), "yesterday afternoon") }
        if has("yesterday evening") { return (at(day(-1), 17), day(0), "yesterday evening") }
        if has("yesterday") { return (day(-1), today, "yesterday") }
        if has("this morning") { return (at(today, 4), at(today, 12), "this morning") }
        if has("this afternoon") { return (at(today, 12), at(today, 18), "this afternoon") }
        if has("(this evening|tonight)") { return (at(today, 17), day(1), "this evening") }
        if has("(today|earlier today|earlier)") { return (today, now, "today") }
        if has("(the other day|a few days ago|couple of days ago)") { return (day(-5), day(-1), "the other day") }
        if has("(this week)") {
            let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? day(-7)
            return (start, now, "this week")
        }
        if has("last week") {
            let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? day(-7)
            return (cal.date(byAdding: .day, value: -7, to: start)!, start, "last week")
        }
        if has("(this|last|past) month") { return (day(-30), now, "in the last month") }
        // A weekday: the most recent one (today's, if it's today; "last tuesday" means the one before).
        let names = cal.weekdaySymbols.map { $0.lowercased() } // Sunday first
        for (i, name) in names.enumerated() where has(name) || has(String(name.prefix(3))) && name.count > 3 && has("(on|last) \(name.prefix(3))") {
            let weekday = cal.component(.weekday, from: now) - 1
            var back = (weekday - i + 7) % 7
            if back == 0, has("last \(name)") { back = 7 }
            let start = day(-back)
            return (start, min(day(-back + 1), now), name.capitalized)
        }
        return nil
    }

    /// Apps named in the question, matched against the apps Recall has seen (and everyday names
    /// for kinds of app: "the terminal", "my browser", "email").
    @MainActor static func apps(in lower: String) -> (names: [String], bundleIDs: [String], matchedWords: [String]) {
        let seen = RecallStore.shared.apps()
        guard !seen.isEmpty else { return ([], [], []) }
        var names: [String] = [], ids: [String] = [], words: [String] = []
        func word(_ w: String) -> Bool { lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: w))\\b", options: .regularExpression) != nil }
        for app in seen where !app.name.isEmpty {
            let name = app.name.lowercased()
            if word(name) {
                names.append(app.name); ids.append(app.bundleID); words += name.split(separator: " ").map(String.init)
            }
        }
        for (kind, matches) in kinds where word(kind) {
            for app in seen where !ids.contains(app.bundleID) && matches.contains(where: { app.bundleID.lowercased().contains($0) || app.name.lowercased().contains($0) }) {
                names.append(app.name); ids.append(app.bundleID)
            }
            words += kind.split(separator: " ").map(String.init)
        }
        return (names, ids, words)
    }

    private static let kinds: [String: [String]] = [
        "terminal": ["terminal", "iterm", "ghostty", "warp", "cmux", "alacritty", "kitty", "wezterm"],
        "browser": ["safari", "chrome", "firefox", "arc", "browser", "vivaldi", "brave", "edge", "opera", "zen", "orion"],
        "web": ["safari", "chrome", "firefox", "arc", "browser", "vivaldi", "brave", "edge", "opera", "zen", "orion"],
        "email": ["mail", "outlook", "spark", "mimestream", "airmail"], "mail": ["mail", "outlook", "spark", "mimestream"],
        "editor": ["xcode", "code", "cursor", "zed", "nova", "sublime", "bbedit", "textmate", "intellij", "vim"],
        "chat": ["slack", "messages", "discord", "telegram", "whatsapp", "teams", "signal"],
    ]

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    @Generable
    struct GuidedFilter {
        @Guide(description: "The app it was in, as the user named it (Slack, Terminal, Safari), or empty if none.")
        var app: String
        @Guide(description: "When it was seen, as the user put it.",
               .anyOf(["any time", "last hour", "today", "this morning", "this afternoon", "yesterday", "this week", "last week",
                       "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]))
        var when: String
        @Guide(description: "Up to 6 words likely to appear in the window's title, address or text. Most distinctive first. No time words, no app names, no words like see/saw/that/thing.",
               .maximumCount(6))
        var keywords: [String]
        @Guide(description: "What it looked like, if the user described its appearance (\"a dark dashboard with a red chart\"); else empty.")
        var looks: String
    }
    #endif

    /// The filter as Apple's model reads it (guided generation, so it's always well-formed).
    static func parseWithModel(_ query: String) async -> Filter? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return nil }
        do {
            let session = LanguageModelSession(instructions: """
            The user is searching a record of what was on their Mac's screen. Read their question into a search filter. \
            Today is \(Date().formatted(date: .complete, time: .omitted)).
            """)
            let guided = try await session.respond(to: query, generating: GuidedFilter.self, options: GenerationOptions(temperature: 0)).content
            var filter = Filter(byModel: true)
            if let time = resolveTime(guided.when.lowercased()) { (filter.from, filter.to, filter.when) = (time.from, time.to, time.label) }
            let found = await MainActor.run { apps(in: guided.app.lowercased()) }
            if !guided.app.isEmpty { filter.apps = found.names; filter.bundleIDs = found.bundleIDs }
            let skip = Set(found.matchedWords)
            filter.keywords = guided.keywords.flatMap { $0.lowercased().split(separator: " ").map(String.init) }
                .filter { $0.count >= 2 && !filler.contains($0) && !skip.contains($0) }
            filter.looks = guided.looks.trimmingCharacters(in: .whitespaces).isEmpty ? nil : guided.looks
            return filter
        } catch {
            DebugHooks.log("Recall: model filter failed: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Ranking

    /// The best captures for a filter, one per window (the best moment of it), best first.
    static func search(_ filter: Filter, query: String, limit: Int = 12) -> [Hit] {
        let store = RecallStore.shared
        let byWords = filter.keywords.isEmpty ? [] :
            store.search(words: filter.keywords, from: filter.from, to: filter.to, bundleIDs: filter.bundleIDs, limit: 300)
        // MobileCLIP judges how captures looked: the newest few hundred in range, so a description
        // finds a window even when none of its words were said.
        var visual: [Int64: Float] = [:]
        var pool = byWords
        let description = filter.looks ?? (filter.keywords.isEmpty ? nil : filter.keywords.joined(separator: " "))
        if let description, VisualSearch.isUsable, let clip = VisualSearch.model, let wanted = try? clip.embed(text: description) {
            let recent = store.search(words: [], from: filter.from, to: filter.to, bundleIDs: filter.bundleIDs, limit: 1500)
            for hit in byWords + recent { if let v = hit.vector { visual[hit.id] = CLIPModel.similarity(wanted, v) } }
            let known = Set(byWords.map(\.id))
            // Only what looks clearly like it joins from outside the word matches.
            pool += recent.filter { !known.contains($0.id) && (visual[$0.id] ?? 0) >= 0.24 }
        }
        if filter.keywords.isEmpty, visual.isEmpty {
            pool = store.search(words: [], from: filter.from, to: filter.to, bundleIDs: filter.bundleIDs, limit: 300)
        }
        guard !pool.isEmpty else { return [] }

        let best = pool.map { -$0.bm25 }.max() ?? 0
        let now = Date()
        // With a time given, nearness to it matters less than the words.
        let halfLife: TimeInterval = filter.from != nil ? 7 * 86_400 : 2 * 86_400
        let scored = pool.map { hit -> Hit in
            let words = best > 0 ? -hit.bm25 / best : 0
            let looks = visual[hit.id].map { Double(min(max(($0 - 0.15) / 0.15, 0), 1)) } ?? 0
            let recency = pow(0.5, now.timeIntervalSince(hit.time) / halfLife)
            let score = filter.keywords.isEmpty && visual.isEmpty ? recency
                : 0.6 * words + (visual.isEmpty ? 0 : 0.25) * looks + 0.15 * recency
            return Hit(id: hit.id, time: hit.time, bundleID: hit.bundleID, appName: hit.appName, title: hit.title,
                       location: hit.location, snippet: hit.snippet, thumbnail: hit.thumbnail, score: score)
        }
        // One per window: the same page captured ten times is one memory.
        var kept: [String: Hit] = [:]
        for hit in scored {
            let key = "\(hit.bundleID ?? "")|\(hit.title ?? "")|\(hit.location ?? "")"
            if let have = kept[key], have.score >= hit.score { continue }
            kept[key] = hit
        }
        return Array(kept.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.time > $1.time }.prefix(limit))
    }

    // MARK: - Answering

    /// Questions ("what was that error…") get a sentence; "the pricing page from Tuesday" just the results.
    static func wantsSentence(_ query: String) -> Bool {
        let l = query.lowercased()
        return l.hasSuffix("?") || ["what ", "when ", "where ", "which ", "who ", "how ", "why "].contains(where: l.hasPrefix)
            || l.hasPrefix("recall what") || l.hasPrefix("recall when") || l.hasPrefix("recall which")
    }

    /// The model's answer from the top captures' text (text only, no pictures). On this Mac only:
    /// never a cloud model, since Recall promises nothing leaves it.
    static func answer(_ query: String, hits: [Hit], onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        let context = hits.prefix(5).enumerated().map { i, hit in
            let text = RecallStore.shared.text(of: hit.id)
            let head = [hit.appName, hit.title, hit.location].compactMap { $0 }.joined(separator: " · ")
            return "[\(i + 1)] \(hit.time.formatted(date: .abbreviated, time: .shortened)) — \(head)\n\(text.prefix(1500))"
        }.joined(separator: "\n\n")
        let system = """
        You answer a question about what the user saw on their Mac's screen, from text read off their windows at the time. \
        Reply in one or two plain sentences: the answer itself (quote an error or a number exactly), and when and where it \
        was seen. If the text doesn't answer it, say which window looks closest. No preamble, no markdown.
        """
        return try await OllamaClient.chatStream(system: system, user: "Question: \(query)\n\nWhat was on screen:\n\(context)",
                                                 allowCloud: false, onText: onText)
    }

    // MARK: - Opening

    /// Back to where it was: the page or document when known, else the app.
    @MainActor static func open(_ hit: Hit) {
        if let location = hit.location {
            if let url = URL(string: location), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) {
                if let id = hit.bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), scheme != "file" {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            if location.hasPrefix("/"), FileManager.default.fileExists(atPath: location) {
                NSWorkspace.shared.open(URL(fileURLWithPath: location))
                return
            }
        }
        if let id = hit.bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
