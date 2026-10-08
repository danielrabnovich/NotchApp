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

    // MARK: - Web clippings

    /// Where links and answers saved from a web search live as small files, so the shelf (which
    /// holds files) can keep them: a .webloc per link, a .txt per answer.
    static var clippingsFolder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp/Shelf Clippings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileName(_ title: String, limit: Int = 60) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Untitled" : cleaned).prefix(limit))
    }

    /// The file a link is saved as: same link, same file, so "already on the shelf" is easy to tell.
    static func linkFile(for url: URL, title: String) -> URL {
        let host = url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? "link"
        return clippingsFolder.appendingPathComponent("\(fileName(title)) – \(host).webloc")
    }

    static func answerFile(for question: String) -> URL {
        clippingsFolder.appendingPathComponent("\(fileName(question)).txt")
    }

    func contains(_ file: URL) -> Bool {
        items.contains { $0.url.standardizedFileURL == file.standardizedFileURL }
    }

    /// Saves a web link as a .webloc (double-click opens it; dragging it out drops the link).
    func addLink(_ url: URL, title: String) {
        let file = Self.linkFile(for: url, title: title)
        if let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0) {
            try? data.write(to: file)
        }
        add([file])
    }

    /// Saves a web answer, with its numbered sources, as a text file.
    func addAnswer(question: String, answer: String, sources: [WebSource]) {
        let file = Self.answerFile(for: question)
        var text = "\(question)\n\n\(answer)\n"
        if !sources.isEmpty {
            text += "\nSources\n" + sources.enumerated().map { "[\($0.offset + 1)] \($0.element.title) – \($0.element.url.absoluteString)" }
                .joined(separator: "\n") + "\n"
        }
        try? text.write(to: file, atomically: true, encoding: .utf8)
        add([file])
    }

    /// The web address inside a .webloc, so dragging it out of the shelf drops a real link.
    static func webLink(in file: URL) -> URL? {
        guard file.pathExtension.lowercased() == "webloc", let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let s = plist["URL"] as? String else { return nil }
        return URL(string: s)
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
