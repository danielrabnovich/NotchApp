import AppKit
import Combine

/// Drops every new screenshot onto the shelf (and the clipboard), wherever macOS saves it. The
/// screenshot folder is watched directly so it lands within a moment; Spotlight catches the rest
/// (screenshots saved somewhere else, or a folder changed later).
@MainActor
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var startedAt = Date()
    private var folderWatch: DispatchSourceFileSystemObject?
    private var watchedFolder: URL?
    private var seen = Set<String>()

    func start() {
        let settings = AppSettings.shared
        settings.$screenshotCatcher.combineLatest(settings.$shelfEnabled)
            .sink { [weak self] catcher, shelf in
                if catcher && shelf { self?.begin() } else { self?.end() }
            }
            .store(in: &cancellables)
    }

    private func begin() {
        guard query == nil else { return }
        startedAt = Date()
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemIsScreenCapture = 1")
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] note in
            let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            MainActor.assumeIsolated { self?.handle(added) }
        }
        q.start()
        query = q
        watchFolder()
    }

    /// Where screenshots are saved: the Screenshot app's chosen folder, or the Desktop.
    private static var screenshotFolder: URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        if let custom, FileManager.default.fileExists(atPath: custom.path) { return custom }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// Opening the folder can wait on a macOS privacy prompt (the Desktop is protected), so it
    /// happens off the main thread; the app would freeze at launch otherwise.
    private func watchFolder() {
        let folder = Self.screenshotFolder
        DispatchQueue.global(qos: .utility).async {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let watcher = ScreenshotWatcher.shared
                    guard watcher.query != nil, watcher.folderWatch == nil else { close(fd); return }
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
                    source.setEventHandler { MainActor.assumeIsolated { ScreenshotWatcher.shared.scanFolder() } }
                    source.setCancelHandler { close(fd) }
                    source.resume()
                    watcher.folderWatch = source
                    watcher.watchedFolder = folder
                }
            }
        }
    }

    /// New files in the folder that macOS marked as screen captures.
    private func scanFolder() {
        guard let folder = watchedFolder else { return }
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        let fresh = files.filter { url in
            guard !seen.contains(url.path),
                  let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  created >= startedAt.addingTimeInterval(-2), Date().timeIntervalSince(created) < 60 else { return false }
            return getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
        }
        guard !fresh.isEmpty else { return }
        catchScreenshots(fresh)
    }

    private func end() {
        folderWatch?.cancel()
        folderWatch = nil
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func handle(_ items: [NSMetadataItem]) {
        let urls: [URL] = items.compactMap { item in
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            let created = item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? Date()
            guard created >= startedAt.addingTimeInterval(-2) else { return nil }
            return URL(fileURLWithPath: path)
        }
        catchScreenshots(urls.filter { !seen.contains($0.path) })
    }

    // MARK: - One shelf item per screenshot

    /// Screenshots that just arrived, held a moment for their twins.
    private var pending: [URL] = []
    private var flushWork: DispatchWorkItem?
    /// Name and size of each screenshot just caught, so a twin arriving later is let go.
    private var recent: [String: Date] = [:]

    /// Some screenshot apps write each capture twice: CleanShot keeps one in its own library
    /// (~/Library/Application Support/CleanShot/media) besides the one in the folder you chose.
    /// Both are marked as screen captures, so new ones wait a moment and twins (same name and
    /// size) make one shelf item.
    private func catchScreenshots(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        seen.formUnion(urls.map(\.path))
        pending += urls
        flushWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { ScreenshotWatcher.shared.flush() } }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// For notchdebug: screenshots arriving, as if just caught.
    func debugCatch(_ urls: [URL]) { catchScreenshots(urls) }

    private func flush() {
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 60 }
        var groups: [String: [URL]] = [:]
        var order: [String] = []
        for url in pending {
            let key = Self.key(url)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(url)
        }
        pending = []
        let picked: [URL] = order.compactMap { key in
            guard recent[key] == nil, let twins = groups[key] else { return nil }
            recent[key] = now
            return twins.min { Self.rank($0) < Self.rank($1) }
        }
        guard !picked.isEmpty else { return }
        ShelfStore.shared.add(picked)
        ActivityCenter.shared.show(.screenshot(count: picked.count), for: 3)
    }

    private static func key(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(url.lastPathComponent)|\(size)"
    }

    /// The copy to keep: one you'd look for (the Desktop, a folder you chose) over an app's own
    /// library or cache.
    private static func rank(_ url: URL) -> Int {
        let path = url.path
        if path.contains("/Library/Application Support/") || path.contains("/Library/Caches/") || path.contains("/Library/Containers/") { return 1 }
        return 0
    }
}
