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
        DispatchQueue.global(qos: .utility).async { [self] in
            let found = Self.scan()
            lock.lock(); apps = found; lock.unlock()
        }
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
            lock.lock(); apps = found; lock.unlock()
            DebugHooks.log("AppIndex: rescanned, \(found.count) apps")
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
        // System Settings lives outside /Applications on recent macOS.
        let settings = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        if fm.fileExists(atPath: settings.path), seen.insert("system settings").inserted {
            result.append(App(name: "System Settings", url: settings))
        }
        return result
    }
}
