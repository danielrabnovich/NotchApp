import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

/// Everything you copy, kept for later: text, links, images and files. Copies marked as
/// concealed or transient (password managers do this) and copies from password apps are skipped.
@MainActor
final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()

    struct Clip: Identifiable, Codable, Equatable {
        enum Kind: String, Codable { case text, link, image, files }

        let id: UUID
        let kind: Kind
        var text: String?
        /// For images: a PNG saved next to the history file.
        var imageFile: String?
        var filePaths: [String]?
        var date: Date
        var pinned = false
        var sourceBundleID: String?

        var title: String {
            switch kind {
            case .text, .link: return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            case .image: return "Image"
            case .files:
                let names = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
                return names.count == 1 ? names[0] : "\(names.count) files"
            }
        }

        /// A picture: copied as an image, or copied files that are all pictures (Finder copies files).
        var isPicture: Bool {
            switch kind {
            case .image: return true
            case .files:
                let paths = filePaths ?? []
                return !paths.isEmpty && paths.allSatisfy {
                    UTType(filenameExtension: ($0 as NSString).pathExtension.lowercased())?.conforms(to: .image) ?? false
                }
            default: return false
            }
        }

        /// A copied hex color ("#FF5733", "#f53", "#FF573380", or "FF5733" as Figma copies it):
        /// its components, so the card can show the color itself.
        var hexColor: (r: Double, g: Double, b: Double, a: Double)? {
            guard kind == .text, var hex = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            let hashed = hex.hasPrefix("#")
            if hashed { hex.removeFirst() }
            // Bare digits need a letter and the full six or eight, so "123456" stays a number.
            guard hex.allSatisfy(\.isHexDigit), hashed ? [3, 4, 6, 8].contains(hex.count)
                    : [6, 8].contains(hex.count) && hex.contains(where: \.isLetter) else { return nil }
            if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard let v = UInt64(hex, radix: 16) else { return nil }
            let c = { (shift: UInt64) in Double((v >> shift) & 0xFF) / 255 }
            return hex.count == 8 ? (c(24), c(16), c(8), c(0)) : (c(16), c(8), c(0), 1)
        }

        var icon: String {
            switch kind {
            case .text: "text.alignleft"
            case .link: "link"
            case .image: "photo"
            case .files: "doc.on.doc"
            }
        }
    }

    @Published private(set) var clips: [Clip] = []
    /// Clips picked in the Clipboard pane (⌘-click, ⇧-click): right-click acts on all of them.
    @Published var selection: Set<UUID> = []
    private var anchor: UUID?

    static let limit = 60
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    /// Our own copies (pasting a clip back) aren't new history.
    private var ignoreChange: Int?

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchApp/Clipboard", isDirectory: true)
    }()
    private var indexURL: URL { folder.appendingPathComponent("history.json") }

    /// Password managers: nothing copied from them is kept, and Recall never captures them.
    nonisolated static let skippedApps: Set<String> = [
        "com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords",
        "com.apple.keychainaccess", "in.sinew.Enpass-Desktop", "com.lastpass.LastPass", "com.dashlane.Dashlane",
        "org.keepassxc.keepassxc", "com.callpod.keeper.mac",
    ]

    private init() {}

    func start() {
        load()
        apply(AppSettings.shared.clipboardHistory || AppSettings.shared.cleanLinks)
    }

    func apply(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        lastChange = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.6, repeats: true) { _ in MainActor.assumeIsolated { ClipboardHistory.shared.poll() } }
        t.tolerance = 0.15 // lets macOS batch this wake-up with others
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Put on what NotchApp copies itself.
    static let ownType = NSPasteboard.PasteboardType("com.notchapp.NotchApp.copied")

    /// The clipboard's current contents are the app's own (a screenshot copied from the shelf).
    func ignoreCurrent() {
        ignoreChange = NSPasteboard.general.changeCount
    }

    /// Lets the clipboard change without keeping anything, for a moment (reading a selection by
    /// copying it, then putting the user's clipboard back).
    func pause(for seconds: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(seconds)
    }
    private var pausedUntil = Date.distantPast

    var pinned: [Clip] { clips.filter(\.pinned) }

    // MARK: - Capture

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if Date() < pausedUntil { return }
        if ignoreChange == pb.changeCount { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        // nspasteboard.org conventions for "don't keep this".
        let private_ = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
                        "com.agilebits.onepassword"]
        guard !types.contains(where: { private_.contains($0) }) else { return }
        let source = types.contains(Self.ownType.rawValue) ? Bundle.main.bundleIdentifier : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let source, Self.skippedApps.contains(source) { return }
        if AppSettings.shared.cleanLinks { cleanLink(pb) }
        guard AppSettings.shared.clipboardHistory, let clip = capture(pb, source: source) else { return }
        add(clip)
    }

    /// A copied link without its tracking, put back on the clipboard in its place. Only a copy that
    /// is a link and nothing else (not files, not a passage with a link in it).
    private func cleanLink(_ pb: NSPasteboard) {
        let types = pb.types ?? []
        guard !types.contains(.fileURL), let string = pb.string(forType: .string), let cleaned = LinkCleaner.clean(string) else { return }
        pb.clearContents()
        pb.setString(cleaned.link, forType: .string)
        pb.setString(cleaned.link, forType: .URL)
        lastChange = pb.changeCount
        let host = URL(string: cleaned.link)?.host()?.replacingOccurrences(of: "www.", with: "") ?? "Link"
        let what = cleaned.removed == 1 ? "1 tracker" : "\(cleaned.removed) trackers"
        ActivityCenter.shared.show(.notice(title: "Link cleaned", detail: "\(host) · took off \(what)", icon: "link"), for: 2)
    }

    private func capture(_ pb: NSPasteboard, source: String?) -> Clip? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return Clip(id: UUID(), kind: .files, filePaths: urls.map(\.path), date: Date(), sourceBundleID: source)
        }
        if let string = pb.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLink = !trimmed.contains(" ") && !trimmed.contains("\n")
                && (URL(string: trimmed).flatMap(\.scheme).map { ["http", "https"].contains($0) } ?? false)
            // Very long copies are kept in full but capped, so the history file stays small.
            return Clip(id: UUID(), kind: isLink ? .link : .text, text: String(string.prefix(20_000)), date: Date(), sourceBundleID: source)
        }
        if let image = NSImage(pasteboard: pb), let png = Self.png(image, maxSide: 1600) {
            let id = UUID()
            let name = "\(id.uuidString).png"
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? png.write(to: folder.appendingPathComponent(name))) != nil else { return nil }
            return Clip(id: id, kind: .image, imageFile: name, date: Date(), sourceBundleID: source)
        }
        return nil
    }

    private func add(_ clip: Clip) {
        var list = clips
        // Copying the same thing again moves it to the front (keeping its pin).
        if let i = list.firstIndex(where: { same($0, clip) }) {
            var existing = list.remove(at: i)
            existing.date = clip.date
            list.insert(existing, at: 0)
            if let file = clip.imageFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
        } else {
            list.insert(clip, at: 0)
        }
        // Over the limit, the oldest unpinned clips go first.
        while list.count > Self.limit, let i = list.lastIndex(where: { !$0.pinned }) {
            remove(fileOf: list.remove(at: i))
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { clips = list }
        save()
    }

    private func same(_ a: Clip, _ b: Clip) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .text, .link: return a.text == b.text
        case .files: return a.filePaths == b.filePaths
        case .image: return false
        }
    }

    // MARK: - Use

    /// Puts a clip back on the clipboard, ready to paste.
    func copy(_ clip: Clip, announce: Bool = true) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch clip.kind {
        case .text, .link:
            pb.setString(clip.text ?? "", forType: .string)
        case .image:
            if let image = image(for: clip) { pb.writeObjects([image]) }
        case .files:
            pb.writeObjects((clip.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL })
        }
        ignoreChange = pb.changeCount
        lastChange = pb.changeCount
        if let i = clips.firstIndex(where: { $0.id == clip.id }) {
            var list = clips
            var moved = list.remove(at: i)
            moved.date = Date()
            list.insert(moved, at: 0)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { clips = list }
            save()
        }
        if announce { ActivityCenter.shared.show(.notice(title: "Copied", detail: String(clip.title.prefix(40)), icon: "doc.on.clipboard"), for: 2) }
    }

    /// Puts a clip back and pastes it into the app you were in, without switching to it first.
    func paste(_ clip: Clip) {
        copy(clip, announce: false)
        pasteClipboard()
    }

    /// Presses ⌘V in the app you were in (the notch closes first, so the keys reach it).
    private func pasteClipboard() {
        let target = FrontmostTracker.shared.userApp
        NotchPresenter.shared.primary?.close()
        guard AXIsProcessTrusted(), let target else {
            ActivityCenter.shared.show(.notice(title: "Copied", detail: "Press ⌘V to paste", icon: "doc.on.clipboard"), for: 2)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier { target.activate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down) // kVK_ANSI_V
                    e?.flags = .maskCommand
                    e?.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// Keeps a clip on the shelf as a file: text as .txt, a link as a .webloc, an image as .png.
    func saveToShelf(_ clip: Clip) {
        let shelf = ShelfStore.shared
        switch clip.kind {
        case .files:
            shelf.add((clip.filePaths ?? []).map { URL(fileURLWithPath: $0) }, pinned: true)
        case .link:
            guard let url = clip.text.flatMap({ URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return }
            shelf.addLink(url, title: url.host() ?? "Link")
        case .text:
            let text = clip.text ?? ""
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Text"
            let file = ShelfStore.free(ShelfStore.answerFile(for: String(firstLine.prefix(40))))
            try? text.write(to: file, atomically: true, encoding: .utf8)
            shelf.add([file], pinned: true)
        case .image:
            guard let source = imageURL(for: clip) else { return }
            let file = ShelfStore.free(ShelfStore.clippingsFolder.appendingPathComponent("Image \(clip.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "."))).png"))
            try? FileManager.default.copyItem(at: source, to: file)
            shelf.add([file], pinned: true)
        }
        ActivityCenter.shared.show(.notice(title: "Saved to Shelf", detail: String(clip.title.prefix(40)), icon: "tray.and.arrow.down.fill", tone: .success), for: 2)
    }

    // MARK: - Several at once

    /// ⌘-click adds or takes away; ⇧-click picks everything from the last pick to it, in `order`.
    func pick(_ clip: Clip, modifiers: NSEvent.ModifierFlags, in order: [Clip]) {
        if modifiers.contains(.shift), let anchor, let a = order.firstIndex(where: { $0.id == anchor }),
           let b = order.firstIndex(where: { $0.id == clip.id }) {
            selection = Set(order[min(a, b)...max(a, b)].map(\.id))
        } else {
            if selection.contains(clip.id) { selection.remove(clip.id) } else { selection.insert(clip.id) }
            anchor = clip.id
        }
    }

    /// What an action on `clip` applies to: everything picked when it's one of them.
    func targets(for clip: Clip) -> [Clip] {
        selection.contains(clip.id) ? clips.filter { selection.contains($0.id) } : [clip]
    }

    /// Several copies as one: their text a line apart, or all their files together.
    func copyTogether(_ group: [Clip], announce: Bool = true) {
        let pb = NSPasteboard.general
        let files = group.flatMap { $0.filePaths ?? [] }.map { URL(fileURLWithPath: $0) as NSURL }
        pb.clearContents()
        if !files.isEmpty, group.allSatisfy({ $0.kind == .files }) {
            pb.writeObjects(files)
        } else {
            pb.setString(group.compactMap(\.text).joined(separator: "\n"), forType: .string)
        }
        ignoreChange = pb.changeCount
        lastChange = pb.changeCount
        if announce {
            ActivityCenter.shared.show(.notice(title: "Copied \(group.count) items", detail: "Together, ready to paste", icon: "doc.on.clipboard"), for: 2)
        }
    }

    /// Pastes them as one into the app you were in.
    func pasteTogether(_ group: [Clip]) {
        copyTogether(group, announce: false)
        pasteClipboard()
    }

    func remove(_ group: [Clip]) {
        let ids = Set(group.map(\.id))
        group.forEach(remove(fileOf:))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { clips.removeAll { ids.contains($0.id) } }
        selection.subtract(ids)
        save()
    }

    func setPinned(_ group: [Clip], _ pinned: Bool) {
        let ids = Set(group.map(\.id))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            for i in clips.indices where ids.contains(clips[i].id) { clips[i].pinned = pinned }
        }
        save()
    }

    /// The words in a copied picture, put on the clipboard.
    func copyText(in clip: Clip) {
        guard let url = imageURL(for: clip) else { return }
        Task {
            let text = await SystemTweaks.recognizeText(in: url)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                ActivityCenter.shared.show(.notice(title: "No text in the image", detail: "Nothing to copy", icon: "text.viewfinder", tone: .warning), for: 2.5)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ActivityCenter.shared.show(.notice(title: "Copied the text", detail: String(text.prefix(48)), icon: "text.viewfinder"), for: 2.5)
        }
    }

    /// A search for the copied text in your browser.
    func searchWeb(_ clip: Clip) {
        let q = String((clip.text ?? "").prefix(300)).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://www.google.com/search?q=\(q)") { NSWorkspace.shared.open(url) }
    }

    func togglePin(_ clip: Clip) {
        guard let i = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { clips[i].pinned.toggle() }
        save()
    }

    func delete(_ clip: Clip) {
        selection.remove(clip.id)
        remove(fileOf: clip)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { clips.removeAll { $0.id == clip.id } }
        save()
    }

    /// Clears everything except pinned clips.
    func clear() {
        clips.filter { !$0.pinned }.forEach(remove(fileOf:))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { clips = clips.filter(\.pinned) }
        save()
    }

    /// What the Clipboard pane lists: pinned first, then newest, narrowed by a search and a kind.
    func shown(matching query: String, kind: Clip.Kind?) -> [Clip] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = pinned + clips.filter { !$0.pinned }
        return list.filter { clip in
            (kind == nil || clip.kind == kind || (kind == .image && clip.isPicture)) && (q.isEmpty || clip.title.lowercased().contains(q)
                || (clip.filePaths ?? []).contains { $0.lowercased().contains(q) })
        }
    }

    func search(_ query: String, limit: Int = 5) -> [Clip] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(clips.prefix(limit)) }
        return Array(clips.filter { $0.title.lowercased().contains(q) }.prefix(limit))
    }

    func imageURL(for clip: Clip) -> URL? { clip.imageFile.map { folder.appendingPathComponent($0) } }

    func image(for clip: Clip) -> NSImage? {
        clip.imageFile.flatMap { NSImage(contentsOf: folder.appendingPathComponent($0)) }
    }

    // MARK: - Storage

    private func remove(fileOf clip: Clip) {
        if let file = clip.imageFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([Clip].self, from: data) else { return }
        clips = saved
    }

    private func save() {
        let snapshot = clips
        let folder = folder, url = indexURL
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    private static func png(_ image: NSImage, maxSide: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}
