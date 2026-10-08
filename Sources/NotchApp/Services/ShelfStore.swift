import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShelfItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var thumbnail: NSImage
    /// The file's icon, for places too small for a page preview to read (the stack under the notch).
    let icon: NSImage
    /// Images, video and PDFs: a preview says more than the icon, even small.
    let isVisual: Bool
    /// When it was dropped (or dropped again): unpinned files expire from then.
    var added: Date
    /// Pinned files stay until removed. Unpinned ones are quick drops: they wait in the stack under
    /// the notch, leave once dragged into another app, and expire.
    @Published var pinned: Bool

    init(url: URL, added: Date = Date(), pinned: Bool = false) {
        self.url = url
        self.added = added
        self.pinned = pinned
        icon = NSWorkspace.shared.icon(forFile: url.path)
        thumbnail = icon
        let type = UTType(filenameExtension: url.pathExtension)
        isVisual = [UTType.image, .audiovisualContent, .pdf].contains { type?.conforms(to: $0) == true }
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

/// Files parked in the notch. Persisted across launches.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    private let key = "shelf.items"
    private var expiryTimer: Timer?

    private struct Stored: Codable {
        let path: String
        let added: Date
        let pinned: Bool
    }

    /// Quick drops: the unpinned files, newest first, as the stack under the notch shows them.
    var stack: [ShelfItem] { items.filter { !$0.pinned }.sorted { $0.added > $1.added } }

    /// Something was dropped in the last few minutes: opening the notch goes to the shelf.
    var hasFreshDrop: Bool { items.contains { !$0.pinned && Date().timeIntervalSince($0.added) < 5 * 60 } }

    func load() {
        let defaults = UserDefaults.standard
        var stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Stored].self, from: $0) }
        if stored == nil, let paths = defaults.stringArray(forKey: "shelf.paths") {
            // From before quick drops: everything already on the shelf was put there to keep.
            stored = paths.map { Stored(path: $0, added: Date(), pinned: true) }
            defaults.removeObject(forKey: "shelf.paths")
        }
        items = (stored ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ShelfItem(url: URL(fileURLWithPath: $0.path), added: $0.added, pinned: $0.pinned) }
        removeExpired()
        save()
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { ShelfStore.shared.removeExpired() }
        }
    }

    /// Parks files. Dropping one that's already here makes it fresh again (so it doesn't expire).
    func add(_ urls: [URL], pinned: Bool = false) {
        var changed = false
        for url in urls where url.isFileURL {
            if let existing = items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                existing.added = Date()
                if pinned, !existing.pinned { existing.pinned = true }
                changed = true
            } else {
                items.append(ShelfItem(url: url, pinned: pinned))
                changed = true
            }
        }
        guard changed else { return }
        objectWillChange.send()
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
        remove([item])
    }

    func remove(_ gone: [ShelfItem]) {
        let ids = Set(gone.map(\.id))
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func setPinned(_ item: ShelfItem, _ pinned: Bool) {
        objectWillChange.send()
        item.pinned = pinned
        item.added = Date()
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Drops unpinned files past their time (and anything whose file has gone). The file itself stays put.
    func removeExpired() {
        let expiry = AppSettings.shared.shelfExpiry
        let now = Date()
        let gone = items.filter { item in
            if !FileManager.default.fileExists(atPath: item.url.path) { return true }
            guard !item.pinned else { return false }
            switch expiry {
            case .hour: return now.timeIntervalSince(item.added) > 3600
            case .endOfDay: return !Calendar.current.isDate(item.added, inSameDayAs: now)
            case .never: return false
            }
        }
        guard !gone.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { remove(gone) }
    }

    private func save() {
        let stored = items.map { Stored(path: $0.url.path, added: $0.added, pinned: $0.pinned) }
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: key)
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
        add([file], pinned: true)
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
        add([file], pinned: true)
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
