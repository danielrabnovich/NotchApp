import AppKit

/// Reads the text in your screenshots (on this Mac, with Vision) so Search can find "that
/// screenshot with the error message". New screenshots are read as they're taken; older ones are
/// read slowly in the background, newest first.
@MainActor
final class ScreenshotText {
    static let shared = ScreenshotText()

    struct Entry: Codable {
        let text: String
        let date: Date
    }

    private var index: [String: Entry] = [:]
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var queue: [URL] = []
    private var working = false
    private var saveWork: DispatchWorkItem?
    /// How many older screenshots to read on first run.
    private let backfillLimit = 400

    private let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchApp/screenshot-text.json")
    }()

    private init() {}

    var count: Int { index.count }

    func apply(_ enabled: Bool) {
        stop()
        guard enabled else { return }
        load()
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemIsScreenCapture = 1")
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSCreationDateKey, ascending: false)]
        observers.append(NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenshotText.shared.gathered() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { note in
            let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            let urls = added.compactMap { ($0.value(forAttribute: NSMetadataItemPathKey) as? String).map(URL.init(fileURLWithPath:)) }
            MainActor.assumeIsolated { ScreenshotText.shared.enqueue(urls, first: true) }
        })
        q.start()
        query = q
    }

    private func stop() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        queue = []
    }

    private func gathered() {
        guard let query else { return }
        query.disableUpdates()
        let urls = (0..<min(query.resultCount, backfillLimit)).compactMap { i -> URL? in
            ((query.result(at: i) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String).map(URL.init(fileURLWithPath:))
        }
        query.enableUpdates()
        // Forget screenshots that were deleted.
        let before = index.count
        index = index.filter { FileManager.default.fileExists(atPath: $0.key) }
        if index.count != before { scheduleSave() }
        enqueue(urls, first: false)
    }

    private func enqueue(_ urls: [URL], first: Bool) {
        let fresh = urls.filter { index[$0.path] == nil && !queue.contains($0) }
        queue = first ? fresh + queue : queue + fresh
        work()
    }

    /// One at a time at background priority, so a big backlog never slows anything down.
    private func work() {
        guard !working, let next = queue.first else { return }
        queue.removeFirst()
        working = true
        Task.detached(priority: .background) {
            let text = await SystemTweaks.recognizeText(in: next) ?? ""
            let created = (try? next.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            await MainActor.run {
                let shared = ScreenshotText.shared
                shared.index[next.path] = Entry(text: text, date: created)
                shared.working = false
                shared.scheduleSave()
                shared.work()
            }
        }
    }

    /// Screenshots whose text contains every word typed, newest first.
    func search(_ query: String, limit: Int = 3) -> [URL] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return [] }
        return index.filter { _, entry in
            let text = entry.text.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        .sorted { $0.value.date > $1.value.date }
        .prefix(limit)
        .map { URL(fileURLWithPath: $0.key) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The line of a screenshot's text that matched, for the result's subtitle.
    func snippet(for url: URL, query: String) -> String? {
        guard let text = index[url.path]?.text else { return nil }
        let first = query.lowercased().split(separator: " ").first.map(String.init) ?? ""
        let line = text.split(whereSeparator: \.isNewline).first { $0.lowercased().contains(first) }
        return line.map { String($0.prefix(80)) }
    }

    // MARK: - Storage

    private func load() {
        guard index.isEmpty, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        index = saved
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func save() {
        let snapshot = index, file = file
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }
}
