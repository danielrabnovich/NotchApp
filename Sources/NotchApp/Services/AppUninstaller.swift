import AppKit
import SwiftUI

/// Removes an app together with the support files it left in ~/Library: everything goes to the
/// Trash, so it can be put back.
@MainActor
final class AppUninstaller: ObservableObject {
    static let shared = AppUninstaller()

    struct Target: Equatable {
        let appURL: URL
        let name: String
        let bundleID: String?
        var appSize: Int64
        var leftovers: [Cleaner.Item]
        var total: Int64 { appSize + leftovers.reduce(0) { $0 + $1.size } }
    }

    @Published private(set) var target: Target?
    @Published private(set) var searching = false
    @Published private(set) var removing = false
    @Published var excluded: Set<URL> = []
    @Published var message: String?

    private init() {}

    /// Places apps keep their data, relative to ~/Library.
    nonisolated private static let locations = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers",
                                    "Saved Application State", "Logs", "HTTPStorages", "WebKit", "Cookies",
                                    "LaunchAgents", "Application Scripts", "Preferences/ByHost"]

    func inspect(_ appURL: URL) {
        guard appURL.pathExtension == "app" else {
            message = "Drop an app (.app) to uninstall it"
            return
        }
        let path = appURL.resolvingSymlinksInPath().path
        guard !path.hasPrefix("/System/"), path != Bundle.main.bundleURL.path else {
            message = "That app is part of macOS"
            return
        }
        let bundle = Bundle(url: appURL)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier
        message = nil
        excluded = []
        searching = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            target = Target(appURL: appURL, name: name, bundleID: bundleID, appSize: 0, leftovers: [])
        }
        Task {
            async let size = Task.detached { Cleaner.allocatedSize(appURL) }.value
            async let found = Task.detached { Self.leftovers(name: name, bundleID: bundleID) }.value
            let (appSize, leftovers) = await (size, found)
            guard target?.appURL == appURL else { return }
            target = Target(appURL: appURL, name: name, bundleID: bundleID, appSize: appSize, leftovers: leftovers)
            searching = false
        }
    }

    /// Finds an installed app by name ("uninstall slack").
    func inspect(named name: String) -> Bool {
        guard let hit = AppIndex.shared.search(name, limit: 1).first, hit.score >= 70 else { return false }
        inspect(hit.app.url)
        return true
    }

    func cancel() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { target = nil }
        searching = false
    }

    var isRunning: Bool {
        guard let id = target?.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    func uninstall() {
        guard let target, !removing else { return }
        let wasRunning = isRunning
        if let id = target.bundleID {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
        }
        removing = true
        let urls = [target.appURL] + target.leftovers.map(\.url).filter { !excluded.contains($0) }
        // Give a quitting app a moment to let go of its files.
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasRunning ? 1.5 : 0)) {
            // NSWorkspace asks for an administrator password itself when the app needs one.
            NSWorkspace.shared.recycle(urls) { moved, error in
                Task { @MainActor in
                    let shared = AppUninstaller.shared
                    shared.removing = false
                    if moved[target.appURL] == nil {
                        shared.message = error.map { "Couldn't remove \(target.name): \($0.localizedDescription)" } ?? "Couldn't remove \(target.name)"
                        return
                    }
                    ActivityCenter.shared.show(.notice(title: "Uninstalled \(target.name)", detail: "\(formatBytes(target.total)) to the Trash",
                                                       icon: "trash.fill"), for: 4)
                    shared.cancel()
                    AppIndex.shared.refreshIfNeeded()
                }
            }
        }
    }

    nonisolated private static func leftovers(name: String, bundleID: String?) -> [Cleaner.Item] {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let id = bundleID?.lowercased()
        let appName = name.lowercased()
        let compactName = appName.replacingOccurrences(of: " ", with: "")
        var found: [URL] = []
        for location in locations {
            let folder = library.appendingPathComponent(location)
            guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for child in children {
                let file = child.lastPathComponent.lowercased()
                let stem = (file as NSString).deletingPathExtension
                var match = false
                if let id {
                    // com.foo.bar, com.foo.bar.plist, com.foo.bar.savedState, TEAMID.com.foo.bar, com.foo.bar.helper
                    match = stem == id || file.hasPrefix(id + ".") || stem.hasSuffix("." + id) || file == id + ".savedstate"
                }
                // Folders named exactly like the app ("Slack" in Application Support). Short or generic
                // names would catch other apps' data, so only exact names of four letters or more count.
                if !match, appName.count >= 4, ["application support", "caches", "logs"].contains(location.lowercased()) {
                    match = file == appName || file == compactName
                }
                if match { found.append(child) }
            }
        }
        return found.map { Cleaner.Item(url: $0, size: Cleaner.allocatedSize($0)) }.sorted { $0.size > $1.size }
    }
}
