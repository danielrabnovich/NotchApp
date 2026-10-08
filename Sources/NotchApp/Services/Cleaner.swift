import AppKit
import SwiftUI

/// Finds space that can safely be given back (caches, logs, developer clutter, installers, old
/// downloads, big forgotten files) and moves what you pick to the Trash, so every clean can be undone.
/// Nothing is scanned or touched outside the folders listed here.
@MainActor
final class Cleaner: ObservableObject {
    static let shared = Cleaner()

    enum CategoryID: String, CaseIterable, Identifiable {
        case appCaches, logs, xcode, devCaches, installers, oldDownloads, largeFiles, trash
        var id: String { rawValue }

        var title: String {
            switch self {
            case .appCaches: "App caches"
            case .logs: "Logs"
            case .xcode: "Xcode"
            case .devCaches: "Package caches"
            case .installers: "Installers"
            case .oldDownloads: "Old downloads"
            case .largeFiles: "Large files"
            case .trash: "Trash"
            }
        }

        var detail: String {
            switch self {
            case .appCaches: "Rebuilt by apps as needed. Apps that are open are skipped."
            case .logs: "Diagnostic logs apps leave behind."
            case .xcode: "DerivedData, device support files and simulator caches."
            case .devCaches: "Homebrew, npm, pip, Yarn, Cargo, Gradle and others."
            case .installers: ".dmg, .pkg and .xip files in Downloads."
            case .oldDownloads: "In Downloads for over a month."
            case .largeFiles: "Over 500 MB and not opened in three months."
            case .trash: "Already in the Trash."
            }
        }

        var icon: String {
            switch self {
            case .appCaches: "archivebox.fill"
            case .logs: "doc.text.fill"
            case .xcode: "hammer.fill"
            case .devCaches: "shippingbox.fill"
            case .installers: "opticaldiscdrive.fill"
            case .oldDownloads: "clock.arrow.circlepath"
            case .largeFiles: "doc.zipper"
            case .trash: "trash.fill"
            }
        }

        var tint: Color {
            switch self {
            case .appCaches: Color(red: 0.36, green: 0.62, blue: 1)
            case .logs: Color(red: 0.6, green: 0.6, blue: 0.68)
            case .xcode: Color(red: 0.3, green: 0.7, blue: 1)
            case .devCaches: Color(red: 0.98, green: 0.73, blue: 0.25)
            case .installers: Color(red: 0.75, green: 0.5, blue: 1)
            case .oldDownloads: Color(red: 0.35, green: 0.8, blue: 0.75)
            case .largeFiles: Color(red: 1, green: 0.55, blue: 0.3)
            case .trash: Color(red: 1, green: 0.4, blue: 0.4)
            }
        }

        /// Safe to clear wholesale: picked by default. The rest are your own files, so you choose.
        var selectedByDefault: Bool { [.appCaches, .logs, .xcode, .devCaches].contains(self) }
    }

    struct Item: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let size: Int64
        var date: Date?
        var name: String { url.lastPathComponent }
    }

    struct Category: Identifiable {
        let id: CategoryID
        var items: [Item]
        var size: Int64 { items.reduce(0) { $0 + $1.size } }
    }

    struct Disk: Equatable {
        let total: Int64
        let available: Int64
        var used: Int64 { total - available }
        var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    @Published private(set) var categories: [CategoryID: Category] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var scanned: Date?
    @Published var selected: Set<CategoryID> = Set(CategoryID.allCases.filter(\.selectedByDefault))
    /// Files inside a picked category that you unticked.
    @Published var excluded: Set<URL> = []
    @Published private(set) var cleaning = false
    @Published private(set) var lastFreed: Int64?
    @Published private(set) var disk: Disk?
    @Published private(set) var snapshots: [String] = []
    @Published var lastError: String?

    private var lowSpaceAlerted: Date?
    private var diskTimer: Timer?

    private init() {}

    func start() {
        refreshDisk()
        let t = Timer(timeInterval: 30 * 60, repeats: true) { _ in MainActor.assumeIsolated { Cleaner.shared.refreshDisk() } }
        RunLoop.main.add(t, forMode: .common)
        diskTimer = t
    }

    var selectedSize: Int64 {
        selected.reduce(0) { total, id in
            total + (categories[id]?.items.filter { !excluded.contains($0.url) }.reduce(0) { $0 + $1.size } ?? 0)
        }
    }

    // MARK: - Disk

    func refreshDisk() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let disk = Disk(total: Int64(total), available: available)
        self.disk = disk
        // A heads-up once a day when space runs low (under 10 GB or 5%).
        let low = disk.available < 10_000_000_000 || Double(disk.available) / Double(max(disk.total, 1)) < 0.05
        if low, AppSettings.shared.lowDiskAlerts, lowSpaceAlerted.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true {
            lowSpaceAlerted = Date()
            ActivityCenter.shared.show(.notice(title: "\(formatBytes(disk.available)) free", detail: "Low disk space · Tools → Cleaner",
                                               icon: "externaldrive.fill.badge.exclamationmark", tone: .warning), for: 6)
        }
    }

    // MARK: - Scan

    func scan() {
        guard !scanning, !cleaning else { return }
        scanning = true
        lastFreed = nil
        lastError = nil
        refreshDisk()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).map { $0.lowercased() })
        Task {
            let found = await withTaskGroup(of: Category.self) { group in
                for id in CategoryID.allCases {
                    group.addTask { await Self.scan(id, running: running) }
                }
                var all: [CategoryID: Category] = [:]
                for await category in group { all[category.id] = category }
                return all
            }
            snapshots = await Self.localSnapshots()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                categories = found
                excluded = excluded.filter { url in found.values.contains { $0.items.contains { $0.url == url } } }
                scanned = Date()
                scanning = false
            }
        }
    }

    nonisolated private static func scan(_ id: CategoryID, running: Set<String>) async -> Category {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        func children(_ path: String) -> [URL] {
            (try? fm.contentsOfDirectory(at: home.appendingPathComponent(path), includingPropertiesForKeys: nil)) ?? []
        }
        func sized(_ urls: [URL]) -> [Item] {
            urls.compactMap { url in
                let size = allocatedSize(url)
                return size > 0 ? Item(url: url, size: size) : nil
            }
            .sorted { $0.size > $1.size }
        }

        switch id {
        case .appCaches:
            let skip = Set(devCacheNames.map { $0.lowercased() } + [Bundle.main.bundleIdentifier?.lowercased() ?? ""])
            let urls = children("Library/Caches").filter { url in
                let name = url.lastPathComponent.lowercased()
                // Apple's own caches are managed (and mostly protected) by macOS.
                return !name.hasPrefix("com.apple.") && !name.hasPrefix(".") && !skip.contains(name) && !running.contains(name)
            }
            return Category(id: id, items: sized(urls))
        case .logs:
            return Category(id: id, items: sized(children("Library/Logs").filter { !$0.lastPathComponent.hasPrefix(".") }))
        case .xcode:
            let roots = ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/iOS DeviceSupport",
                         "Library/Developer/Xcode/watchOS DeviceSupport", "Library/Developer/Xcode/macOS DeviceSupport",
                         "Library/Developer/CoreSimulator/Caches"]
            return Category(id: id, items: sized(roots.flatMap(children)))
        case .devCaches:
            let paths = devCacheNames.map { "Library/Caches/\($0)" } + [".npm/_cacache", ".cargo/registry/cache", ".gradle/caches",
                                                                       ".bun/install/cache", "Library/pnpm/store", ".cache/pip",
                                                                       ".cache/yarn", "go/pkg/mod/cache"]
            let urls = paths.map { home.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
            return Category(id: id, items: sized(urls))
        case .installers, .oldDownloads:
            let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Downloads")
            let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
            let urls = (try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            let installerTypes: Set<String> = ["dmg", "pkg", "mpkg", "xip"]
            let cutoff = Date().addingTimeInterval(-30 * 86_400)
            let picked: [Item] = urls.compactMap { url in
                let isInstaller = installerTypes.contains(url.pathExtension.lowercased())
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = values?.addedToDirectoryDate ?? values?.contentModificationDate
                if id == .installers ? !isInstaller : (isInstaller || (date ?? Date()) > cutoff) { return nil }
                let size = allocatedSize(url)
                return size > 0 ? Item(url: url, size: size, date: date) : nil
            }
            return Category(id: id, items: picked.sorted { $0.size > $1.size })
        case .largeFiles:
            return Category(id: id, items: await largeFiles(in: home))
        case .trash:
            // Reading the Trash needs Full Disk Access on recent macOS; without it this stays empty.
            let size = allocatedSize(home.appendingPathComponent(".Trash"))
            return Category(id: id, items: size > 0 ? [Item(url: home.appendingPathComponent(".Trash"), size: size)] : [])
        }
    }

    /// Cache folders that belong to developer tools (they're listed under Package caches instead).
    nonisolated static let devCacheNames = ["Homebrew", "pip", "Yarn", "CocoaPods", "go-build", "node-gyp", "pnpm",
                                            "typescript", "org.swift.swiftpm", "pypoetry", "deno", "bazel", "composer"]

    /// Spotlight knows file sizes already, so this is quick even across the whole home folder.
    nonisolated private static func largeFiles(in home: URL) async -> [Item] {
        let result = await Shell.run("/usr/bin/mdfind", ["-onlyin", home.path, "kMDItemFSSize > 500000000"], timeout: 20)
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let library = home.appendingPathComponent("Library").path + "/"
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .contentModificationDateKey, .isPackageKey, .isDirectoryKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        return result.out.split(separator: "\n").compactMap { line -> Item? in
            let path = String(line)
            // Skip app data, anything inside an app or package, and hidden folders.
            guard !path.hasPrefix(library), !path.contains(".app/"), !path.contains("/."),
                  !path.hasSuffix(".app") else { return nil }
            let url = URL(fileURLWithPath: path)
            guard let v = try? url.resourceValues(forKeys: keys), v.isDirectory != true else { return nil }
            let used = max(v.contentAccessDate ?? .distantPast, v.contentModificationDate ?? .distantPast)
            guard used < cutoff else { return nil }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            return size > 0 ? Item(url: url, size: size, date: used) : nil
        }
        .sorted { $0.size > $1.size }
        .prefix(40)
        .map { $0 }
    }

    nonisolated static func allocatedSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            if let v = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    // MARK: - Clean

    /// Moves everything picked to the Trash (and empties the Trash if that was picked).
    func clean() {
        guard !cleaning, !scanning else { return }
        let picked = selected.filter { $0 != .trash }
        let urls = picked.flatMap { categories[$0]?.items ?? [] }.map(\.url).filter { !excluded.contains($0) }
        let freed = selectedSize
        let emptyTrash = selected.contains(.trash)
        guard !urls.isEmpty || emptyTrash else { return }
        cleaning = true
        lastError = nil
        let finish: @MainActor (String?) -> Void = { [weak self] error in
            guard let self else { return }
            self.cleaning = false
            self.lastError = error
            if error == nil {
                self.lastFreed = freed
                ActivityCenter.shared.show(.notice(title: emptyTrash ? "Freed \(formatBytes(freed))" : "\(formatBytes(freed)) to the Trash",
                                                   detail: emptyTrash ? "Cleaner" : "Cleaner · empty the Trash to free it",
                                                   icon: "sparkles"), for: 4)
            }
            self.scan()
        }
        let trashThenFinish: @MainActor (String?) -> Void = { error in
            guard emptyTrash else { finish(error); return }
            Self.emptyTrash { ok in finish(error ?? (ok ? nil : "Allow NotchApp to control Finder in Privacy & Security → Automation")) }
        }
        guard !urls.isEmpty else { trashThenFinish(nil); return }
        NSWorkspace.shared.recycle(urls) { _, error in
            // Some items may be in use or protected; the rest still go.
            let message = error.map { _ in "Some items couldn't be moved (they may be in use)" }
            Task { @MainActor in trashThenFinish(message) }
        }
    }

    func emptyTrashNow() {
        selected = [.trash]
        clean()
    }

    nonisolated static func emptyTrash(completion: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
            let ok = error == nil
            Task { @MainActor in completion(ok) }
        }
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Time Machine

    nonisolated private static func localSnapshots() async -> [String] {
        let result = await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 10)
        return result.out.split(separator: "\n").map(String.init).filter { $0.contains("com.apple.TimeMachine") }
    }

    /// Local snapshots hold deleted files' space until macOS frees it; removing them needs a password.
    func deleteSnapshots() {
        Task {
            let ok = await Shell.runAsAdmin("/usr/bin/tmutil deletelocalsnapshots /")
            if !ok { lastError = "Time Machine snapshots weren't deleted" }
            snapshots = await Self.localSnapshots()
            refreshDisk()
        }
    }
}
