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
    /// A caught screenshot: it cleans itself up (see `ShelfStore.screenshotLifetime`) unless pinned.
    let isScreenshot: Bool

    init(url: URL, added: Date = Date(), pinned: Bool = false, isScreenshot: Bool = false) {
        self.url = url
        self.added = added
        self.pinned = pinned
        self.isScreenshot = isScreenshot
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

    /// What the shelf calls it: its own name, or a made-up one (Random file names).
    @MainActor var name: String { ShelfNames.isOn(for: url) ? ShelfNames.alias(for: url) : url.lastPathComponent }
}

/// Files parked in the notch. Persisted across launches.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    /// Files picked on the shelf (click, ⌘-click, ⇧-click): right-click and dragging act on all of them.
    @Published var selection: Set<UUID> = []
    /// Files waiting for a conversion to be picked on the shelf (dropped on "More…").
    @Published var convertPicker: [URL]?
    private let key = "shelf.items"
    private var expiryTimer: Timer?

    private struct Stored: Codable {
        let path: String
        let added: Date
        let pinned: Bool
        var screenshot: Bool? = nil
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
            .map { ShelfItem(url: URL(fileURLWithPath: $0.path), added: $0.added, pinned: $0.pinned, isScreenshot: $0.screenshot ?? false) }
        removeExpired()
        save()
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { ShelfStore.shared.removeExpired() }
        }
    }

    /// Parks files. Dropping one that's already here makes it fresh again (so it doesn't expire).
    /// `copy: false` keeps it off the clipboard whatever "Copy what you add" says (a batch's
    /// conversions, which would otherwise each replace the last).
    func add(_ urls: [URL], pinned: Bool = false, screenshot: Bool? = nil, copy: Bool = true) {
        var changed = false
        let originals = urls.filter(\.isFileURL)
        let files = originals.map(Self.keepIfTemporary)
        for (original, url) in zip(originals, files) {
            if let existing = items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                existing.added = Date()
                if pinned, !existing.pinned { existing.pinned = true }
                changed = true
            } else {
                items.append(ShelfItem(url: url, pinned: pinned, isScreenshot: screenshot ?? Self.isScreenshot(original)))
                changed = true
            }
        }
        guard changed else { return }
        objectWillChange.send()
        save()
        if copy, AppSettings.shared.copyShelfAdds { copyLater(files) }
    }

    // MARK: - Temporary files

    /// Shelf copies of files that were about to disappear.
    static var keptFolder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp/Shelf Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A file in a temporary folder (the screenshot thumbnail's, an app's drag cache) is deleted
    /// soon after it's dropped, so the shelf keeps its own copy.
    private static func keepIfTemporary(_ url: URL) -> URL {
        let path = url.resolvingSymlinksInPath().path
        let temporary = path.contains("/TemporaryItems/") || path.hasPrefix("/private/var/folders/")
            || path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        guard temporary, FileManager.default.fileExists(atPath: path) else { return url }
        let folder = keptFolder
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        // A drag can hand over access to a folder the app otherwise can't read (the screenshot
        // thumbnail's lives in a protected one).
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            // copyItem also carries over the folder's protections; the bytes alone are enough.
            do {
                try Data(contentsOf: url).write(to: target)
                return target
            } catch {
                DebugHooks.log("Shelf: couldn't keep \(url.path): \(error)")
                return url
            }
        }
    }

    /// Deletes kept copies that are no longer on the shelf. Only ever touches the shelf's own folder.
    private func cleanKeptFolder() {
        let folder = Self.keptFolder.standardizedFileURL
        let onShelf = Set(items.map(\.url.standardizedFileURL.path))
        let kept = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in kept where !onShelf.contains(file.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Copying the latest drop

    private var pendingCopy: [URL] = []
    private var copyWork: DispatchWorkItem?

    /// Puts what was just added on the clipboard, ready to paste anywhere. A multi-file drop arrives
    /// one file at a time, so adds that land together are gathered and copied as one.
    private func copyLater(_ urls: [URL]) {
        pendingCopy += urls.filter { new in !pendingCopy.contains { $0.standardizedFileURL == new.standardizedFileURL } }
        copyWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let store = ShelfStore.shared
                Self.copy(store.pendingCopy)
                store.pendingCopy = []
                // Copied for you, not by you: Clipboard history has it on the shelf already.
                ClipboardHistory.shared.ignoreCurrent()
            }
        }
        copyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Kept alive for as long as its screenshot is on the clipboard.
    private static var screenshotOnClipboard: ScreenshotPaste?

    /// Files paste as files; a saved link pastes as the link itself.
    /// An image also goes on as image data, for places that paste pictures but not files
    /// (chat apps in the browser, Notes, documents).
    static func copy(_ urls: [URL]) {
        let originals = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        // What goes on the clipboard: under a made-up name, with Random file names on.
        let urls = originals.map(ShelfNames.outgoing)
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if urls.count == 1, let link = webLink(in: urls[0]) {
            pb.writeObjects([link as NSURL])
            pb.setString(link.absoluteString, forType: .string)
        } else if urls.count == 1, AppSettings.shared.screenshotCleanup,
                  ShelfStore.shared.items.contains(where: { $0.url == originals[0] && $0.isScreenshot }),
                  let provider = ScreenshotPaste(url: originals[0], handed: urls[0]) {
            let entry = NSPasteboardItem()
            screenshotOnClipboard = provider
            entry.setDataProvider(provider, forTypes: provider.types)
            pb.writeObjects([entry])
            ClipboardHistory.shared.ignoreCurrent()
        } else {
            let entries: [NSPasteboardItem] = urls.map { url in
                let entry = NSPasteboardItem()
                entry.setString(url.absoluteString, forType: .fileURL)
                if urls.count == 1, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                   let data = try? Data(contentsOf: url) {
                    let type = NSPasteboard.PasteboardType(UTType(filenameExtension: url.pathExtension)?.identifier ?? "")
                    entry.setData(data, forType: type)
                    if type != .png, type != .tiff, let tiff = NSImage(data: data)?.tiffRepresentation {
                        entry.setData(tiff, forType: .tiff)
                    }
                }
                return entry
            }
            pb.writeObjects(entries)
        }
        // Marked as NotchApp's, so Clipboard history credits it and not whichever app is in front.
        pb.addTypes([ClipboardHistory.ownType], owner: nil)
        pb.setData(Data(), forType: ClipboardHistory.ownType)
        DebugHooks.log("Shelf: copied \(urls.map(\.lastPathComponent)) types=\(pb.types?.map(\.rawValue) ?? [])")
    }

    /// Takes a drop onto the notch. A screenshot dragged from its floating thumbnail names a file in
    /// a folder the app may not be allowed to read, but the drag also carries the picture itself,
    /// so the shelf saves that instead.
    @discardableResult
    func addDrop(from pb: NSPasteboard) -> Bool {
        var urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let fromScreenshot = urls.contains { Self.isScreenshot($0) }
        let unreadable = urls.count <= 1 && !urls.contains { FileManager.default.isReadableFile(atPath: $0.path) }
        if unreadable, let png = pb.data(forType: .png)
            ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
            let name = urls.first.map { $0.deletingPathExtension().lastPathComponent }
                ?? "Image \(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second()))"
            let target = Self.keptFolder.appendingPathComponent(name).appendingPathExtension("png")
            if (try? png.write(to: target)) != nil { urls = [target] }
        }
        guard !urls.isEmpty else { return false }
        add(urls, screenshot: fromScreenshot ? true : nil)
        return true
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

    /// A file converted in place: the new one takes the old one's spot (and pin). False when the
    /// old one isn't here.
    @discardableResult
    func replace(_ old: URL, with new: URL) -> Bool {
        guard let i = items.firstIndex(where: { $0.url.standardizedFileURL == old.standardizedFileURL }) else { return false }
        let item = items[i]
        items[i] = ShelfItem(url: new, added: item.added, pinned: item.pinned, isScreenshot: item.isScreenshot)
        selection.remove(item.id)
        save()
        return true
    }

    func remove(_ gone: [ShelfItem]) {
        let ids = Set(gone.map(\.id))
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        save()
    }

    // MARK: - Selection

    /// The order the shelf shows its files in: quick drops (newest first), then pinned ones.
    var shown: [ShelfItem] { stack + items.filter(\.pinned) }

    /// A click on a file: picks just it; ⌘ adds or takes it away; ⇧ picks everything from the last pick to it.
    func click(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchor = item.id
        } else if modifiers.contains(.shift), let anchor, let a = shown.firstIndex(where: { $0.id == anchor }),
                  let b = shown.firstIndex(where: { $0.id == item.id }) {
            selection = Set(shown[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = selection == [item.id] ? [] : [item.id]
            anchor = item.id
        }
    }
    private var anchor: UUID?

    /// The keyboard's pick: just this file (an arrow), or from the last pick to it (⇧ and an arrow).
    func pick(_ item: ShelfItem, extending: Bool) {
        if extending, anchor != nil {
            click(item, modifiers: .shift)
        } else {
            selection = [item.id]
            anchor = item.id
        }
    }

    /// What an action on `item` applies to: everything picked when it's one of them, else just it.
    func targets(for item: ShelfItem) -> [ShelfItem] {
        selection.contains(item.id) ? shown.filter { selection.contains($0.id) } : [item]
    }

    var selectedItems: [ShelfItem] { shown.filter { selection.contains($0.id) } }

    func selectAll() { selection = Set(items.map(\.id)) }

    // MARK: - File actions

    /// Moves the files themselves to a folder; the shelf follows them there.
    func move(_ moving: [ShelfItem], to folder: URL) {
        var moved: [(ShelfItem, URL)] = []
        for item in moving {
            let target = Self.free(folder.appendingPathComponent(item.url.lastPathComponent))
            do {
                try FileManager.default.moveItem(at: item.url, to: target)
                moved.append((item, target))
            } catch {
                DebugHooks.log("Shelf: couldn't move \(item.url.path): \(error)")
            }
        }
        guard !moved.isEmpty else {
            ActivityCenter.shared.show(.notice(title: "Couldn't move", detail: folder.lastPathComponent, icon: "folder", tone: .warning), for: 3)
            return
        }
        let replacements = moved.map { ShelfItem(url: $1, added: $0.added, pinned: $0.pinned, isScreenshot: $0.isScreenshot) }
        let ids = Set(moved.map(\.0.id))
        items.removeAll { ids.contains($0.id) }
        items.append(contentsOf: replacements)
        selection.subtract(ids)
        save()
        ActivityCenter.shared.show(.notice(title: moved.count == 1 ? "Moved to \(folder.lastPathComponent)" : "Moved \(moved.count) files",
                                           detail: moved.count == 1 ? moved[0].1.lastPathComponent : folder.lastPathComponent,
                                           icon: "folder.fill", tone: .success), for: 2.5)
    }

    /// Files a drag moved somewhere else (Finder took the originals): the shelf follows each to its
    /// new place, or lets it go when it can't be found (moved to another disk). A screenshot put
    /// somewhere on purpose is no longer one to clean up.
    func follow(_ moved: [(ShelfItem, URL?)]) {
        let replacements = moved.compactMap { item, url in
            url.map { ShelfItem(url: $0, added: item.added, pinned: item.pinned) }
        }
        let ids = Set(moved.map(\.0.id))
        withAnimation(Motion.pane.animation) {
            items.removeAll { ids.contains($0.id) }
            items.append(contentsOf: replacements)
        }
        selection.subtract(ids)
        save()
    }

    /// Asks where to move them.
    func chooseFolderAndMove(_ moving: [ShelfItem]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = moving.count == 1 ? "Move “\(moving[0].url.lastPathComponent)” to…" : "Move \(moving.count) files to…"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        move(moving, to: folder)
    }

    /// The files to the Trash, and off the shelf.
    func trash(_ gone: [ShelfItem]) {
        for item in gone { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { remove(gone) }
    }

    /// "Report.zip" for one file, "Archive.zip" for several.
    nonisolated static func zipName(for urls: [URL]) -> String {
        (urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive") + ".zip"
    }

    /// Zips the files into `output` (Finder's kind of zip, through ditto). Slow for big files: off
    /// the main thread.
    nonisolated static func makeZip(_ urls: [URL], to output: URL) -> Bool {
        guard let first = urls.first else { return false }
        if urls.count == 1 {
            return Shell.runSync("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, output.path], timeout: 600).ok
        }
        // ditto zips one folder: gather clones of the files in one (instant on APFS).
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchApp Zip \(UUID().uuidString)/\(output.deletingPathExtension().lastPathComponent)")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for url in urls { try? FileManager.default.copyItem(at: url, to: staging.appendingPathComponent(url.lastPathComponent)) }
        let ok = Shell.runSync("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, output.path], timeout: 600).ok
        try? FileManager.default.removeItem(at: staging.deletingLastPathComponent())
        return ok
    }

    /// A zip of the files, next to the first one (or in Downloads), put on the shelf.
    func compress(_ files: [ShelfItem]) {
        let urls = files.map(\.url)
        guard let first = urls.first else { return }
        let folder = FileManager.default.isWritableFile(atPath: first.deletingLastPathComponent().path)
            ? first.deletingLastPathComponent() : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = Self.zipName(for: urls)
        let output = Self.free(folder.appendingPathComponent(name))
        Task.detached {
            let ok = Self.makeZip(urls, to: output)
            await MainActor.run {
                if ok {
                    ShelfStore.shared.add([output])
                    ActivityCenter.shared.show(.notice(title: "Compressed", detail: "\(output.lastPathComponent) · \(formatBytes(Cleaner.allocatedSize(output)))",
                                                       icon: "doc.zipper", tone: .success), for: 3)
                } else {
                    ActivityCenter.shared.show(.notice(title: "Couldn't compress", detail: name, icon: "doc.zipper", tone: .warning), for: 3)
                }
            }
        }
    }

    /// Copies of the files next to them ("Report copy.pdf"), on the shelf.
    func duplicate(_ files: [ShelfItem]) {
        var made: [URL] = []
        for item in files {
            let base = item.url.deletingPathExtension().lastPathComponent + " copy"
            let target = Self.free(item.url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(item.url.pathExtension))
            if (try? FileManager.default.copyItem(at: item.url, to: target)) != nil { made.append(target) }
        }
        add(made)
    }

    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The words in a picture, on the clipboard.
    static func copyTextInImage(_ url: URL) {
        Task {
            let text = await SystemTweaks.recognizeText(in: url)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                ActivityCenter.shared.show(.notice(title: "No text in the image", detail: url.lastPathComponent, icon: "text.viewfinder", tone: .warning), for: 2.5)
                return
            }
            copyText(text)
            ActivityCenter.shared.show(.notice(title: "Copied the text", detail: String(text.prefix(48)), icon: "text.viewfinder"), for: 2.5)
        }
    }

    /// The paths, one a line, for pasting into a terminal or a message.
    static func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// `url`, or "name 2.ext" (and so on) when that's taken.
    nonisolated static func free(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent(), ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let next = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: next.path) { return next }
            n += 1
        }
    }

    func setPinned(_ item: ShelfItem, _ pinned: Bool) {
        objectWillChange.send()
        item.pinned = pinned
        item.added = Date()
        save()
    }

    func clear() {
        items.removeAll()
        selection = []
        save()
    }

    /// Drops unpinned files past their time (and anything whose file has gone). The file itself stays put.
    func removeExpired() {
        let expiry = AppSettings.shared.shelfExpiry
        let now = Date()
        let gone = items.filter { item in
            if !FileManager.default.fileExists(atPath: item.url.path) { return true }
            guard !item.pinned else { return false }
            if item.isScreenshot, AppSettings.shared.screenshotCleanup,
               now.timeIntervalSince(item.added) > Self.screenshotLifetime { return true }
            switch expiry {
            case .hour: return now.timeIntervalSince(item.added) > 3600
            case .endOfDay: return !Calendar.current.isDate(item.added, inSameDayAs: now)
            case .never: return false
            }
        }
        guard !gone.isEmpty else { return }
        let cleanup = gone.filter { $0.isScreenshot && AppSettings.shared.screenshotCleanup }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { remove(gone) }
        cleanup.forEach { Self.trash($0.url) }
    }

    // MARK: - Screenshots

    /// How long a caught screenshot stays before it's cleaned up (or a minute after it's pasted).
    static let screenshotLifetime: TimeInterval = 15 * 60

    /// macOS marks screenshots it saves; one dragged from the floating thumbnail comes from its folder.
    static func isScreenshot(_ url: URL) -> Bool {
        url.path.contains("screencaptureui")
            || getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    /// Someone pasted a screenshot the shelf copied: give the app a minute to finish reading the
    /// file, then clean it up.
    fileprivate func screenshotPasted(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            MainActor.assumeIsolated {
                let store = ShelfStore.shared
                guard AppSettings.shared.screenshotCleanup,
                      let item = store.items.first(where: { $0.url == url }), item.isScreenshot, !item.pinned else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.remove(item) }
                Self.trash(url)
            }
        }
    }

    /// Screenshots on the Desktop go to the Trash; the shelf's own copies are simply deleted.
    private static func trash(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if url.standardizedFileURL.path.hasPrefix(keptFolder.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private func save() {
        cleanKeptFolder()
        let stored = items.map { Stored(path: $0.url.path, added: $0.added, pinned: $0.pinned, screenshot: $0.isScreenshot) }
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

/// Puts a screenshot on the clipboard lazily, so the app hears when something actually pastes it.
/// Reads in the first moment are clipboard managers looking at the new copy, not a paste.
private final class ScreenshotPaste: NSObject, NSPasteboardItemDataProvider {
    /// The screenshot on the shelf (reported when pasted), and the file handed over (the same, or a
    /// copy under a made-up name).
    let url: URL
    let handed: URL
    let png: Data
    let copiedAt = Date()
    let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
    private var reported = false

    init?(url: URL, handed: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.url = url
        self.handed = handed
        png = data
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .fileURL: item.setString(handed.absoluteString, forType: .fileURL)
        case .png: item.setData(png, forType: .png)
        case .tiff: if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        default: return
        }
        guard !reported, Date().timeIntervalSince(copiedAt) > 1.5 else { return }
        reported = true
        let url = url
        DispatchQueue.main.async { MainActor.assumeIsolated { ShelfStore.shared.screenshotPasted(url) } }
    }
}


/// Made-up names for files on the shelf (Settings → Shelf → Random file names): "amber-harbor-27.png".
/// The name comes from the file's path and a secret kept on this Mac, so it stays the same for as
/// long as the file is there and can't be traced back to the original name. Nothing is renamed:
/// what's dragged or copied out is a copy under the made-up name (a clone, so it takes no space).
@MainActor
enum ShelfNames {
    static func isOn(for url: URL) -> Bool {
        AppSettings.shared.shelfRandomNames && url.isFileURL && ShelfStore.webLink(in: url) == nil
    }

    private static let first = ["amber", "quiet", "silver", "misty", "golden", "velvet", "hollow", "crisp", "lunar", "copper",
                                "mellow", "frosted", "drifting", "sunny", "pale", "brisk", "dusky", "gentle", "wild", "still",
                                "coral", "ivory", "olive", "slate", "rosy", "hazy", "bright", "calm", "nimble", "sleepy", "tidal", "woven"]
    private static let second = ["harbor", "meadow", "comet", "pebble", "willow", "lantern", "canyon", "orchid", "falcon", "glacier",
                                 "ember", "thistle", "lagoon", "summit", "maple", "otter", "prism", "fern", "dune", "heron",
                                 "aurora", "cove", "ripple", "birch", "quarry", "sparrow", "tundra", "cedar", "marble", "breeze", "atlas", "kite"]

    /// A secret made on first use, so the names say nothing about the files.
    private static var salt: String {
        if let s = UserDefaults.standard.string(forKey: "shelfNameSalt") { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: "shelfNameSalt")
        return s
    }

    static func alias(for url: URL) -> String {
        let hash = (salt + url.standardizedFileURL.path).unicodeScalars
            .reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1.value)) &* 1_099_511_628_211 }
        let a = first[Int(hash % UInt64(first.count))]
        let b = second[Int((hash >> 16) % UInt64(second.count))]
        let n = Int((hash >> 32) % 90) + 10
        let ext = url.pathExtension
        return ext.isEmpty ? "\(a)-\(b)-\(n)" : "\(a)-\(b)-\(n).\(ext.lowercased())"
    }

    /// The file to hand over when it leaves the shelf: the original, or a copy under its made-up
    /// name (in a temporary folder macOS clears by itself).
    static func outgoing(_ url: URL) -> URL {
        guard isOn(for: url) else { return url }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("NotchApp Shelf/\(abs(url.path.hashValue))", isDirectory: true)
        let target = folder.appendingPathComponent(alias(for: url))
        if fm.fileExists(atPath: target.path) { return target }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: target) // a clone on APFS: instant, no extra space
            return target
        } catch {
            return url
        }
    }
}
