import AppKit

/// Installed apps, for "open spotify" and launching apps straight from the search bar.
final class AppIndex: @unchecked Sendable {
    static let shared = AppIndex()

    struct App: Identifiable, Equatable {
        /// The name Finder shows (the bundle's file name).
        let name: String
        let url: URL
        /// Other names to match, e.g. VS Code's bundle calls itself just "Code".
        var aliases: [String] = []
        var id: String { url.path }
    }

    private let lock = NSLock()
    private var apps: [App] = []
    private var loadedAt: Date?

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
        DispatchQueue.global(qos: .utility).async { [self] in
            let found = Self.scan()
            lock.lock(); apps = found; lock.unlock()
        }
    }

    /// Best matches, strongest first, with a 0–100 score.
    func search(_ query: String, limit: Int = 3) -> [(app: App, score: Int)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        lock.lock(); let all = apps; lock.unlock()
        return all.compactMap { app -> (App, Int)? in
            let score = ([app.name] + app.aliases).map { Self.score($0.lowercased(), q) }.max() ?? 0
            return score > 0 ? (app, score) : nil
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.count < $1.0.name.count }
        .prefix(limit)
        .map { (app: $0.0, score: $0.1) }
    }

    private static func score(_ name: String, _ q: String) -> Int {
        if name == q { return 100 }
        if name.hasPrefix(q) { return 85 }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
        if words.contains(where: { $0.hasPrefix(q) }) { return 70 }
        let initials = String(words.compactMap(\.first))
        if q.count >= 2, initials.hasPrefix(q) { return 60 }
        if q.count >= 3, name.contains(q) { return 45 }
        // Letters in order ("vsc" → Visual Studio Code).
        if q.count >= 3 {
            var it = name.makeIterator()
            if q.allSatisfy({ c in while let n = it.next() { if n == c { return true } }; return false }) { return 25 }
        }
        return 0
    }

    private static func scan() -> [App] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     "/System/Library/CoreServices/Applications", "\(home)/Applications"]
        var seen = Set<String>()
        var result: [App] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(item)
                let bundle = Bundle(url: url)
                let name = url.deletingPathExtension().lastPathComponent
                let aliases = [bundle?.localizedInfoDictionary?["CFBundleDisplayName"], bundle?.infoDictionary?["CFBundleDisplayName"],
                               bundle?.infoDictionary?["CFBundleName"]]
                    .compactMap { $0 as? String }.filter { $0.lowercased() != name.lowercased() }
                guard seen.insert(name.lowercased()).inserted else { continue }
                result.append(App(name: name, url: url, aliases: Array(Set(aliases))))
            }
        }
        // System Settings lives outside /Applications on recent macOS.
        let settings = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        if fm.fileExists(atPath: settings.path), seen.insert("system settings").inserted {
            result.append(App(name: "System Settings", url: settings))
        }
        return result
    }
}
