import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor
final class ShelfItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var thumbnail: NSImage

    init(url: URL) {
        self.url = url
        thumbnail = NSWorkspace.shared.icon(forFile: url.path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbnail = image }
        }
    }

    var name: String { url.lastPathComponent }
}

/// Files temporarily parked in the notch. Persisted across launches.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    private let key = "shelf.paths"

    func load() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(ShelfItem.init)
    }

    func add(_ urls: [URL]) {
        let existing = Set(items.map(\.url.standardizedFileURL))
        let fresh = urls.filter { $0.isFileURL && !existing.contains($0.standardizedFileURL) }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh.map(ShelfItem.init))
        save()
    }

    /// Accepts drops from SwiftUI's `onDrop`.
    @discardableResult
    func add(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { ShelfStore.shared.add([url]) }
            }
        }
        return !fileProviders.isEmpty
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: key)
    }

    // MARK: - AirDrop

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    static func urls(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(urls) } }
    }
}
