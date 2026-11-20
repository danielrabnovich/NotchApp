import AppKit
import CoreServices

/// Xcode builds (and `xcodebuild` runs, an agent's included) as a ring beside the notch, then a
/// Banner with how it went. Nothing to set up: DerivedData is watched with FSEvents. A build starts
/// when its project's Build folder starts changing (not the indexer's, which never stops) and ends
/// when Xcode writes the result to the project's log manifest.
///
/// Xcode says nothing about progress outside its window, so the ring fills on how long the same
/// project's last build took, and waits just short of full until the result is in.
@MainActor
final class XcodeBuilds {
    static let shared = XcodeBuilds()

    private struct Build {
        let started: Date
        var lastActivity: Date
        let expected: TimeInterval?
    }

    private var stream: FSEventStreamRef?
    private var builds: [String: Build] = [:]
    private var ticker: Timer?
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    private let durationsKey = "xcodeBuildDurations"

    func start() {
        guard stream == nil, FileManager.default.fileExists(atPath: root.path) else { return }
        var context = FSEventStreamContext()
        let callback: FSEventStreamCallback = { _, _, count, paths, _, _ in
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let changed = Array(list.prefix(count))
            DispatchQueue.main.async { MainActor.assumeIsolated { XcodeBuilds.shared.changed(changed) } }
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    /// The project folder (DerivedData/<Name-hash>) a path is in, and what changed inside it.
    private func project(of path: String) -> (folder: String, rest: String)? {
        let base = root.path + "/"
        guard path.hasPrefix(base) else { return nil }
        let inside = path.dropFirst(base.count)
        guard let slash = inside.firstIndex(of: "/") else { return nil }
        return (base + inside[..<slash], String(inside[slash...]))
    }

    private func changed(_ paths: [String]) {
        var finished = Set<String>()
        for path in paths {
            guard let (folder, rest) = project(of: path) else { continue }
            if rest.hasSuffix("/Logs/Build/LogStoreManifest.plist") {
                finished.insert(folder)
            } else if rest.hasPrefix("/Build/Intermediates.noindex/") || rest.hasPrefix("/Build/Products/") {
                // The indexer's own build lives under Index.noindex and is never shown.
                if var build = builds[folder] {
                    build.lastActivity = Date()
                    builds[folder] = build
                } else {
                    builds[folder] = Build(started: Date(), lastActivity: Date(), expected: durations[name(of: folder)])
                    update(folder)
                    Breaks.shared.buildStarted(name(of: folder))
                }
            }
        }
        finished.forEach(finish)
        tick()
    }

    private func finish(_ folder: String) {
        guard let build = builds.removeValue(forKey: folder) else { return }
        ProgressCenter.shared.removeExternal(id(folder))
        let manifest = URL(fileURLWithPath: folder + "/Logs/Build/LogStoreManifest.plist")
        guard let data = try? Data(contentsOf: manifest),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let logs = (plist["logs"] as? [String: [String: Any]])?.values,
              let latest = logs.max(by: { ($0["timeStoppedRecording"] as? Double ?? 0) < ($1["timeStoppedRecording"] as? Double ?? 0) }) else { return }
        let stopped = Date(timeIntervalSinceReferenceDate: latest["timeStoppedRecording"] as? Double ?? 0)
        // Only this build's result: one older than its start is a different run's.
        guard stopped > build.started.addingTimeInterval(-5) else { return }
        let began = Date(timeIntervalSinceReferenceDate: latest["timeStartedRecording"] as? Double ?? 0)
        let seconds = max(0, stopped.timeIntervalSince(began))
        let result = latest["primaryObservable"] as? [String: Any] ?? [:]
        let errors = result["totalNumberOfErrors"] as? Int ?? 0
        let warnings = result["totalNumberOfWarnings"] as? Int ?? 0
        let testFailures = result["totalNumberOfTestFailures"] as? Int ?? 0
        let testing = (latest["title"] as? String ?? "").hasPrefix("Test")
        let name = latest["schemeIdentifier-schemeName"] as? String ?? name(of: folder)
        if errors == 0, seconds > 1 { remember(seconds, for: self.name(of: folder)) }

        let took = CommandHandler.duration(seconds)
        let (title, tone): (String, NoticeTone) =
            errors > 0 ? ("\(name) didn't build", .warning)
            : testFailures > 0 ? ("\(testFailures) \(testFailures == 1 ? "test" : "tests") failed in \(name)", .warning)
            : (testing ? "\(name) tests passed" : "\(name) built", .success)
        let detail = [errors > 0 ? "\(errors) \(errors == 1 ? "error" : "errors")" : nil,
                      warnings > 0 ? "\(warnings) \(warnings == 1 ? "warning" : "warnings")" : nil,
                      "\(took)"].compactMap { $0 }.joined(separator: " · ")
        ActivityCenter.shared.show(.notice(title: title, detail: detail, icon: "hammer.fill", tone: tone), for: 6) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").first?.activate()
        }
    }

    /// Rings move every second while something builds; a build that went quiet for a minute with
    /// no result (stopped, or Xcode quit) just goes.
    private func tick() {
        let now = Date()
        for (folder, build) in builds where now.timeIntervalSince(build.lastActivity) > 60 {
            builds[folder] = nil
            ProgressCenter.shared.removeExternal(id(folder))
        }
        builds.keys.forEach(update)
        if builds.isEmpty {
            ticker?.invalidate()
            ticker = nil
        } else if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { XcodeBuilds.shared.tick() } }
        }
    }

    private func update(_ folder: String) {
        guard let build = builds[folder] else { return }
        let elapsed = Date().timeIntervalSince(build.started)
        let fraction = build.expected.map { min(0.95, elapsed / max(1, $0)) }
        let item = ProgressCenter.Item(id: id(folder), title: "Building \(name(of: folder))", fraction: fraction,
                                       bundlePath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")?.path,
                                       target: nil, label: fraction == nil ? CommandHandler.duration(elapsed) : nil,
                                       detail: build.expected.map { "Last build took \(CommandHandler.duration($0))" })
        ProgressCenter.shared.setExternal(item, owner: nil)
    }

    private func id(_ folder: String) -> String { "xcode:" + folder }

    /// "Pep-ddhpvpwebhakkocvzpljosxzexkd" → "Pep".
    private func name(of folder: String) -> String {
        let last = (folder as NSString).lastPathComponent
        guard let dash = last.lastIndex(of: "-") else { return last }
        return String(last[..<dash])
    }

    private var durations: [String: Double] {
        UserDefaults.standard.dictionary(forKey: durationsKey) as? [String: Double] ?? [:]
    }

    private func remember(_ seconds: Double, for project: String) {
        var all = durations
        // A running average, so one clean build after many incremental ones doesn't throw it off.
        all[project] = all[project].map { $0 * 0.6 + seconds * 0.4 } ?? seconds
        UserDefaults.standard.set(all, forKey: durationsKey)
    }
}
