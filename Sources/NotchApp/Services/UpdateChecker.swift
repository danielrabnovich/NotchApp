import AppKit
import Combine

/// Finds available updates from Homebrew (formulae and casks) and from apps that update
/// themselves with Sparkle (by reading their appcast feeds).
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Update: Identifiable, Equatable {
        enum Source: Equatable { case formula, cask, sparkle(appURL: URL) }
        let name: String
        let installed: String
        let available: String
        let source: Source
        var id: String { "\(name)|\(source)" }

        var appURL: URL? {
            if case .sparkle(let url) = source { return url }
            return nil
        }
    }

    @Published private(set) var updates: [Update] = []
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    /// Package names currently upgrading.
    @Published private(set) var upgrading: Set<String> = []
    @Published private(set) var lastError: String?
    /// The update list is showing in the Controls tab.
    @Published var listOpen = false

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var announced: Set<String> = []

    nonisolated static let brew: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func start() {
        AppSettings.shared.$updateChecks.removeDuplicates()
            .sink { [weak self] on in DispatchQueue.main.async { self?.schedule(on) } }
            .store(in: &cancellables)
    }

    private func schedule(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { updates = []; return }
        // Shortly after launch, then every six hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check() }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateChecker.shared.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check() {
        guard !checking else { return }
        checking = true
        lastError = nil
        let includeSparkle = AppSettings.shared.updateChecksApps
        Task.detached {
            async let brew = Self.brewOutdated()
            async let sparkle = includeSparkle ? Self.sparkleUpdates() : []
            let (b, s) = await (brew, sparkle)
            await MainActor.run {
                let me = UpdateChecker.shared
                // Apps installed as casks are already covered by Homebrew.
                let caskNames = Set(b.filter { $0.source == .cask }.map { $0.name.lowercased() })
                let merged = b + s.filter { !caskNames.contains($0.name.lowercased().replacingOccurrences(of: " ", with: "-")) }
                me.updates = merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                me.checking = false
                me.lastChecked = Date()
                me.announceNew()
            }
        }
    }

    private func announceNew() {
        let fresh = updates.filter { !announced.contains($0.id) }
        announced.formUnion(updates.map(\.id))
        guard !fresh.isEmpty, AppSettings.shared.updateAlerts else { return }
        let detail = fresh.count == 1 ? "\(fresh[0].name) \(fresh[0].available)" : fresh.prefix(3).map(\.name).joined(separator: ", ")
            + (fresh.count > 3 ? " +\(fresh.count - 3)" : "")
        ActivityCenter.shared.show(.notice(title: fresh.count == 1 ? "Update available" : "\(fresh.count) updates available",
                                           detail: detail, icon: "arrow.down.app.fill"), for: 5)
    }

    // MARK: - Updating

    func upgrade(_ update: Update) {
        switch update.source {
        case .sparkle(let url):
            // Sparkle apps update themselves; opening them shows their own update prompt.
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .formula, .cask:
            runUpgrade([update])
        }
    }

    /// Debug hooks: shows packages as updating, without running anything.
    func debugUpgrading(_ names: [String]) { upgrading = Set(names) }

    func upgradeAllHomebrew() {
        runUpgrade(updates.filter { $0.source == .formula || $0.source == .cask })
    }

    private func runUpgrade(_ items: [Update]) {
        guard let brew = Self.brew, !items.isEmpty else { return }
        let names = items.map(\.name).filter { !upgrading.contains($0) }
        guard !names.isEmpty else { return }
        upgrading.formUnion(names)
        let casks = items.filter { $0.source == .cask }.map(\.name)
        let formulae = items.filter { $0.source == .formula }.map(\.name)
        Task.detached {
            let failedFormulae = !formulae.isEmpty && Self.run(brew, ["upgrade"] + formulae).code != 0
            let failedCasks = !casks.isEmpty && Self.run(brew, ["upgrade", "--cask"] + casks).code != 0
            let failures = (failedFormulae ? formulae : []) + (failedCasks ? casks : [])
            await MainActor.run {
                let me = UpdateChecker.shared
                me.upgrading.subtract(names)
                me.updates.removeAll { names.contains($0.name) && !failures.contains($0.name) && $0.appURL == nil }
                if failures.isEmpty {
                    ActivityCenter.shared.show(.notice(title: "Updated", detail: names.count == 1 ? names[0] : "\(names.count) packages",
                                                       icon: "checkmark.seal.fill"), for: 3)
                } else {
                    me.lastError = "Couldn't update \(failures.joined(separator: ", ")). Try `brew upgrade` in Terminal."
                }
            }
        }
    }

    // MARK: - Homebrew

    nonisolated private static func brewOutdated() async -> [Update] {
        guard let brew else { return [] }
        // Refresh the package index first so "outdated" knows about new versions.
        _ = run(brew, ["update", "--quiet"])
        let out = run(brew, ["outdated", "--json=v2"], env: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
        guard out.code == 0, let data = out.text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        func parse(_ key: String, _ source: Update.Source) -> [Update] {
            (obj[key] as? [[String: Any]] ?? []).compactMap { item in
                guard let name = item["name"] as? String else { return nil }
                let installed = (item["installed_versions"] as? [String])?.last ?? "?"
                let current = item["current_version"] as? String ?? "?"
                if (item["pinned"] as? Bool) == true { return nil }
                return Update(name: name, installed: installed, available: current, source: source)
            }
        }
        return parse("formulae", .formula) + parse("casks", .cask)
    }

    // MARK: - Sparkle

    nonisolated private static func sparkleUpdates() async -> [Update] {
        let fm = FileManager.default
        let dirs = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var apps: [(URL, String, String, String, URL)] = []
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                guard let info = Bundle(url: url)?.infoDictionary,
                      let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https" else { continue }
                let short = info["CFBundleShortVersionString"] as? String ?? ""
                let build = info["CFBundleVersion"] as? String ?? ""
                apps.append((url, url.deletingPathExtension().lastPathComponent, short, build, feed))
            }
        }
        return await withTaskGroup(of: Update?.self) { group in
            for (url, name, short, build, feed) in apps {
                group.addTask {
                    guard let latest = await latestInAppcast(feed) else { return nil }
                    let newer: Bool
                    if let s = latest.short, !short.isEmpty, compare(s, short) != 0 {
                        newer = compare(s, short) > 0
                    } else {
                        newer = compare(latest.build, build) > 0
                    }
                    return newer ? Update(name: name, installed: short.isEmpty ? build : short,
                                          available: latest.short ?? latest.build, source: .sparkle(appURL: url)) : nil
                }
            }
            var out: [Update] = []
            for await u in group { if let u { out.append(u) } }
            return out
        }
    }

    nonisolated private static func latestInAppcast(_ url: URL) async -> (build: String, short: String?)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let parser = AppcastParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        xml.parse()
        // Highest version across items (appcasts aren't always newest-first).
        return parser.items.filter { !$0.build.isEmpty }.max { compare($0.build, $1.build) < 0 }
    }

    /// Compares dotted version strings numerically ("1.10" > "1.9"); returns -1, 0 or 1.
    nonisolated static func compare(_ a: String, _ b: String) -> Int {
        let parts = { (s: String) in s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    private final class AppcastParser: NSObject, XMLParserDelegate {
        var items: [(build: String, short: String?)] = []
        private var inItem = false
        private var build = ""
        private var short: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if name == "item" { inItem = true; build = ""; short = nil }
            if inItem, name == "enclosure" {
                if let v = attributes["sparkle:version"], build.isEmpty { build = v }
                if let s = attributes["sparkle:shortVersionString"], short == nil { short = s }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if inItem {
                if name == "sparkle:version", !value.isEmpty { build = value }
                if name == "sparkle:shortVersionString", !value.isEmpty { short = value }
                if name == "item" {
                    inItem = false
                    items.append((build, short))
                }
            }
        }
    }

    // MARK: - Process

    nonisolated private static func run(_ cmd: String, _ args: [String], env: [String: String] = [:]) -> (code: Int32, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment.merge(env) { $1 }
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
