import AppKit
import NotchKit

/// Installed apps, for "open spotify" and launching apps straight from the search bar.
final class AppIndex: @unchecked Sendable {
    static let shared = AppIndex()

    struct App: Identifiable, Equatable {
        /// The name Finder shows (the bundle's file name).
        let name: String
        let url: URL
        /// Other names to match, e.g. VS Code's bundle calls itself just "Code".
        var aliases: [String] = [] {
            didSet { matchNames = ([name] + aliases).map(FuzzyMatch.Name.init) }
        }
        /// The name and aliases, split up for matching.
        private(set) var matchNames: [FuzzyMatch.Name]
        var id: String { url.path }

        init(name: String, url: URL, aliases: [String] = []) {
            self.name = name
            self.url = url
            self.aliases = aliases
            matchNames = ([name] + aliases).map(FuzzyMatch.Name.init)
        }
    }

    private let lock = NSLock()
    private var apps: [App] = []
    private var loadedAt: Date?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var rescanPending = false

    /// Words that mean "launch this app" rather than "find a file about it".
    static let launchPrefixes = ["open ", "launch ", "start ", "run "]

    static func stripLaunchPrefix(_ q: String) -> (name: String, explicit: Bool) {
        let lower = q.lowercased()
        for p in launchPrefixes where lower.hasPrefix(p) { return (String(q.dropFirst(p.count)), true) }
        return (q, false)
    }

    /// Rescans at most every five minutes, off the main thread.
    func refreshIfNeeded() {
        lock.lock()
        let stale = loadedAt.map { Date().timeIntervalSince($0) > 300 } ?? true
        if stale { loadedAt = Date() }
        lock.unlock()
        guard stale else { return }
        DispatchQueue.global(qos: .utility).async { [self] in store(Self.scan()) }
    }

    /// A scan's result. The first lands after the bar may already be in use: what's typed is
    /// matched again, so apps don't stay missing until the next keystroke.
    private func store(_ found: [App]) {
        lock.lock(); let first = apps.isEmpty; apps = found; lock.unlock()
        if first { Task { @MainActor in SearchSuggestions.shared.refresh() } }
    }

    /// Rescans whenever an app folder changes (an app installed, moved or removed), and when an
    /// app starts that isn't in the list yet (one installed somewhere else).
    func watch() {
        guard watchers.isEmpty else { return }
        for root in Self.roots {
            let fd = open(root, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                                   queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.rescanSoon() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                                          queue: nil) { [weak self] note in
            guard let self, let url = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL,
                  url.path.hasPrefix("/Applications") || url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path) else { return }
            lock.lock(); let known = apps.contains { $0.url.standardizedFileURL == url.standardizedFileURL }; lock.unlock()
            if !known { rescanSoon() }
        }
    }

    /// A moment after the folder changes: an app being copied in lands as its folder first.
    private func rescanSoon() {
        lock.lock()
        let already = rescanPending
        rescanPending = true
        lock.unlock()
        guard !already else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock(); rescanPending = false; loadedAt = Date(); lock.unlock()
            let found = Self.scan()
            store(found)
            DebugHooks.log("AppIndex: rescanned, \(found.count) apps")
        }
    }

    /// Best matches, strongest first, with a 0–100 score (`FuzzyMatch`'s tiers).
    func search(_ query: String, limit: Int = 3) -> [(app: App, score: Int)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        lock.lock(); let all = apps; lock.unlock()
        let usage = usageBoosts()
        let picks = pickBoosts(for: q)
        return all.compactMap { app -> (App, Int)? in
            let score = app.matchNames.map { FuzzyMatch.score($0, q) }.max() ?? 0
            // What's opened from here often and lately ranks higher among its matches, and what
            // was picked for this very query higher still.
            return score > 0 ? (app, min(100, score + (usage[app.id] ?? 0) + (picks[app.id] ?? 0))) : nil
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.count < $1.0.name.count }
        .prefix(limit)
        .map { (app: $0.0, score: $0.1) }
    }

    // MARK: - What gets opened

    /// Per app (by path): how often it's been opened from search and when last, kept in defaults.
    private static let usageKey = "appIndex.usage"
    private var usage: [String: [Double]]?

    /// An app was opened from search: it'll rank a little higher next time, and first for
    /// `query` (what was typed to find it).
    func noteOpened(_ url: URL, query: String? = nil) {
        if let query { notePick(url, query: query) }
        lock.lock(); defer { lock.unlock() }
        var all = usage ?? (UserDefaults.standard.dictionary(forKey: Self.usageKey) as? [String: [Double]] ?? [:])
        let old = all[url.path] ?? [0, 0]
        all[url.path] = [old[0] + 1, Date().timeIntervalSince1970]
        // Only the 200 most recent are kept.
        if all.count > 200 {
            for key in all.sorted(by: { $0.value[1] < $1.value[1] }).prefix(all.count - 200).map(\.key) { all[key] = nil }
        }
        usage = all
        UserDefaults.standard.set(all, forKey: Self.usageKey)
    }

    /// Up to 15 points per app: more for apps opened often, fading over a month or so unused. Only
    /// enough to order similar matches and lift a word match ("code") above a weak one, never to
    /// put a stray letter match over a name that starts with what's typed.
    private func usageBoosts() -> [String: Int] {
        lock.lock()
        if usage == nil { usage = UserDefaults.standard.dictionary(forKey: Self.usageKey) as? [String: [Double]] ?? [:] }
        let all = usage ?? [:]
        lock.unlock()
        let now = Date().timeIntervalSince1970
        return all.mapValues { entry in
            let days = max(0, now - (entry.count > 1 ? entry[1] : 0)) / 86_400
            let fade = pow(0.5, days / 30)
            return Int((min(15, 5 * log2(1 + (entry.first ?? 0))) * fade).rounded())
        }
    }

    // MARK: - What gets picked for what's typed

    /// The app last opened for each query ("lm" → LM Studio), so it comes first for that query
    /// even when another name fits as well. Kept in defaults.
    private struct Pick: Codable {
        var path: String
        var date: Date
    }
    private static let picksKey = "appIndex.picks"
    private var picks: [String: Pick]?

    private static func pickKey(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func loadedPicks() -> [String: Pick] {
        if let picks { return picks }
        let stored = UserDefaults.standard.data(forKey: Self.picksKey).flatMap { try? JSONDecoder().decode([String: Pick].self, from: $0) }
        picks = stored ?? [:]
        return picks ?? [:]
    }

    private func notePick(_ url: URL, query: String) {
        let key = Self.pickKey(query)
        guard key.count >= 2 else { return }
        lock.lock(); defer { lock.unlock() }
        var all = loadedPicks()
        all[key] = Pick(path: url.path, date: Date())
        // Only the 300 most recent are kept.
        if all.count > 300 {
            for old in all.sorted(by: { $0.value.date < $1.value.date }).prefix(all.count - 300).map(\.key) { all[old] = nil }
        }
        picks = all
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.picksKey) }
    }

    /// 25 points for the app picked for exactly this query, enough to lead (two initials become a
    /// strong match), and 10 for one picked for a query this starts ("lm" on the way to "lms").
    private func pickBoosts(for query: String) -> [String: Int] {
        let key = Self.pickKey(query)
        lock.lock(); let all = loadedPicks(); lock.unlock()
        var out: [String: Int] = [:]
        for (typed, pick) in all where typed.hasPrefix(key) {
            out[pick.path] = max(out[pick.path] ?? 0, typed == key ? 25 : 10)
        }
        return out
    }

    // MARK: - Finding apps

    private static var roots: [String] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
         "/System/Library/CoreServices/Applications", FileManager.default.homeDirectoryForCurrentUser.path + "/Applications"]
    }

    /// The apps in a folder, and in the folders inside it (suites like Adobe's, Setapp, Chrome's web apps).
    private static func bundles(in root: String) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let base = URL(fileURLWithPath: root)
        var found: [URL] = []
        for item in items where !item.hasPrefix(".") {
            let url = base.appendingPathComponent(item)
            if item.hasSuffix(".app") { found.append(url); continue }
            // Utilities is a root of its own; anything else that's a folder gets one look inside.
            guard url.path != "/Applications/Utilities", url.path != "/System/Applications/Utilities",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let inner = try? fm.contentsOfDirectory(atPath: url.path) else { continue }
            found += inner.filter { $0.hasSuffix(".app") }.map { url.appendingPathComponent($0) }
        }
        return found
    }

    private static func scan() -> [App] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [App] = []
        for root in roots {
            for url in bundles(in: root) {
                let bundle = Bundle(url: url)
                let name = url.deletingPathExtension().lastPathComponent
                let aliases = [bundle?.localizedInfoDictionary?["CFBundleDisplayName"], bundle?.infoDictionary?["CFBundleDisplayName"],
                               bundle?.infoDictionary?["CFBundleName"]]
                    .compactMap { $0 as? String }.filter { $0.lowercased() != name.lowercased() }
                guard seen.insert(name.lowercased()).inserted else { continue }
                result.append(App(name: name, url: url, aliases: Array(Set(aliases))))
            }
        }
        // Apps elsewhere that have been opened (Steam's games, one run from Downloads), as Spotlight
        // knows them: build products, copies in the Trash and apps inside apps aside.
        let skip = ["/DerivedData/", "/build/", "/.build/", "/.Trash/", "/Caches/", "/RollbackBackups/", ".app/"]
        let opened = FileFinder.mdfind("kMDItemContentType == 'com.apple.application-bundle' && kMDItemLastUsedDate == *",
                                       limit: 300, scope: nil) { path in
            !path.hasPrefix("/System/") && !skip.contains { path.contains($0) }
        }
        for url in opened {
            let name = url.deletingPathExtension().lastPathComponent
            guard Bundle(url: url)?.infoDictionary?["LSBackgroundOnly"] as? Bool != true,
                  seen.insert(name.lowercased()).inserted else { continue }
            result.append(App(name: name, url: url))
        }
        // System Settings lives outside /Applications on recent macOS, and Finder in CoreServices.
        for (name, path) in [("System Settings", "/System/Applications/System Settings.app"),
                             ("Finder", "/System/Library/CoreServices/Finder.app")]
        where fm.fileExists(atPath: path) && seen.insert(name.lowercased()).inserted {
            result.append(App(name: name, url: URL(fileURLWithPath: path)))
        }
        return result
    }
}
