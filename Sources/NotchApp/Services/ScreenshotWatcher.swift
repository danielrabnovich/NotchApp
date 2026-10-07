import AppKit
import Combine

/// Drops every new screenshot onto the shelf, wherever macOS saves it.
@MainActor
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var startedAt = Date()

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
    }

    private func end() {
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
        guard !urls.isEmpty else { return }
        ShelfStore.shared.add(urls)
        ActivityCenter.shared.show(.screenshot(count: urls.count), for: 3)
    }
}
