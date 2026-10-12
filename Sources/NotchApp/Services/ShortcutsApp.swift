import AppKit
import SwiftUI

/// The user's own Shortcuts (Apple's Shortcuts app), run through `/usr/bin/shortcuts`: by name from
/// the search bar, as actions for the app a Shortcuts folder is named after, and as a Glance.
@MainActor
final class ShortcutsApp: ObservableObject {
    static let shared = ShortcutsApp()

    struct Shortcut: Identifiable, Hashable {
        let id: String
        let name: String
        /// The Shortcuts folder it's in, if any.
        var folder: String?

        /// The Shortcuts app hides its icons from other apps, so a glyph is the initial on one of its colors.
        var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
        var color: Color {
            let palette: [Color] = [
                Color(red: 0.98, green: 0.36, blue: 0.4), Color(red: 1, green: 0.58, blue: 0.2), Color(red: 0.98, green: 0.78, blue: 0.2),
                Color(red: 0.3, green: 0.8, blue: 0.45), Color(red: 0.25, green: 0.75, blue: 0.8), Color(red: 0.3, green: 0.55, blue: 1),
                Color(red: 0.5, green: 0.42, blue: 0.95), Color(red: 0.85, green: 0.4, blue: 0.85),
            ]
            // A stable hash (Swift's own changes per launch), so a Shortcut keeps its color.
            let hash = name.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
            return palette[Int((hash >> 7) % UInt32(palette.count))]
        }
    }

    /// Every Shortcut, in the Shortcuts app's order.
    @Published private(set) var all: [Shortcut] = []
    /// The ones kept beside the notch (IDs, in order). Saved.
    @Published private(set) var glance: [String] {
        didSet { UserDefaults.standard.set(glance, forKey: "shortcutGlances") }
    }
    /// Running now, by ID: their glyphs pulse.
    @Published private(set) var running: Set<String> = []

    static let glanceLimit = 3
    /// How many glyphs the Shortcuts Glance draws, for its width.
    nonisolated(unsafe) static var glanceCount = 0

    private nonisolated static let tool = "/usr/bin/shortcuts"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: tool) }

    private var loadedAt: Date?
    private var loading = false

    private init() {
        glance = UserDefaults.standard.stringArray(forKey: "shortcutGlances") ?? []
        Self.glanceCount = glance.count
    }

    // MARK: - The list

    /// Reads the list again when it's a minute old; it's quick (`shortcuts list` takes ~20 ms).
    func refreshIfStale() {
        guard Self.isAvailable, !loading, loadedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        loading = true
        Task.detached(priority: .utility) {
            let list = Self.load()
            await MainActor.run {
                let me = ShortcutsApp.shared
                me.loading = false
                me.loadedAt = Date()
                if list != me.all {
                    me.all = list
                    // A folder named after the app in front may have new actions for it.
                    AppActions.shared.refresh()
                }
                me.updateGlanceCount()
            }
        }
    }

    /// "Name (UUID)" lines, with each folder's Shortcuts marked.
    private nonisolated static func load() -> [Shortcut] {
        let result = Shell.runSync(tool, ["list", "--show-identifiers"], timeout: 10)
        guard result.ok else { return [] }
        var list = parse(result.out)
        let folders = Shell.runSync(tool, ["list", "--folders"], timeout: 10).out
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        for folder in folders.prefix(40) {
            let ids = Set(parse(Shell.runSync(tool, ["list", "--folder-name", folder, "--show-identifiers"], timeout: 10).out).map(\.id))
            for i in list.indices where ids.contains(list[i].id) { list[i].folder = folder }
        }
        return list
    }

    /// Names can hold brackets of their own, so the ID is the last "(…)" on the line.
    nonisolated static func parse(_ out: String) -> [Shortcut] {
        out.split(separator: "\n").compactMap { line in
            guard line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) else { return nil }
            let id = line[open.upperBound..<line.index(before: line.endIndex)]
            guard UUID(uuidString: String(id)) != nil else { return nil }
            return Shortcut(id: String(id), name: String(line[..<open.lowerBound]))
        }
    }

    func shortcut(id: String) -> Shortcut? { all.first { $0.id == id } }

    /// Shortcuts whose name has every typed word, names starting with it first.
    func matches(_ query: String, limit: Int) -> [Shortcut] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let words = q.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return Array(all.prefix(limit)) }
        return all.filter { s in words.allSatisfy(s.name.lowercased().contains) }
            .sorted { ($0.name.lowercased().hasPrefix(q) ? 0 : 1, $0.name.count) < ($1.name.lowercased().hasPrefix(q) ? 0 : 1, $1.name.count) }
            .prefix(limit).map { $0 }
    }

    /// The Shortcuts in a folder named after an app ("Safari", "Final Cut Pro"): that app's own actions.
    func forApp(named name: String) -> [Shortcut] {
        let app = name.lowercased()
        return all.filter { $0.folder?.lowercased() == app }
    }

    // MARK: - As commands

    /// A search-bar row that runs a Shortcut, with what's selected in the app in front as its input.
    func command(_ s: Shortcut, context: AppContext?) -> Command {
        let input = Self.input(from: context)
        let subtitle: String = switch input {
        case .text?: "Shortcut · with the selected text"
        case .files(let urls)?: urls.count == 1 ? "Shortcut · with \(urls[0].lastPathComponent)" : "Shortcut · with \(urls.count) selected files"
        case nil: s.folder.map { "Shortcut in \($0)" } ?? "Shortcut"
        }
        var command = Command(action: .perform(.init(id: "shortcut:" + s.id) { ShortcutsApp.shared.run(s, input: input) }),
                              title: s.name, subtitle: subtitle, icon: "square.2.layers.3d.fill", verb: "Run")
        command.key = "shortcut:" + s.id
        return command
    }

    enum Input: Equatable {
        case text(String)
        case files([URL])
    }

    static func input(from context: AppContext?) -> Input? {
        guard let context else { return nil }
        if !context.files.isEmpty { return .files(context.files) }
        if let text = context.selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(text) }
        return nil
    }

    // MARK: - Running

    /// Runs a Shortcut in the background. Text it hands back is shown and copied; a picture or file
    /// goes on the Shelf. Returns the line the notch shows while it starts.
    @discardableResult
    func run(_ s: Shortcut, input: Input? = nil) -> String? {
        guard !running.contains(s.id) else { return "“\(s.name)” is already running" }
        running.insert(s.id)
        Task {
            let result = await Self.execute(id: s.id, input: input)
            running.remove(s.id)
            finish(s, result)
        }
        return "Running “\(s.name)”"
    }

    private struct Outcome: Sendable {
        var ok: Bool
        var error: String?
        var output: URL?
    }

    private nonisolated static func execute(id: String, input: Input?) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: executeSync(id: id, input: input))
            }
        }
    }

    private nonisolated static func executeSync(id: String, input: Input?) -> Outcome {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NotchApp-Shortcuts/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var args = ["run", id]
        switch input {
        case .text(let text):
            let file = dir.appendingPathComponent("input.txt")
            try? text.write(to: file, atomically: true, encoding: .utf8)
            args += ["--input-path", file.path]
        case .files(let urls):
            for url in urls { args += ["--input-path", url.path] }
        case nil: break
        }
        let output = dir.appendingPathComponent("output")
        args += ["--output-path", output.path]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return Outcome(ok: false, error: "Couldn't start the shortcuts tool") }
        // A Shortcut can wait on you (a menu, dictation), so it gets a while before it's stopped.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: killer)
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let message = String(data: errData, encoding: .utf8)?
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        return Outcome(ok: p.terminationStatus == 0, error: message, output: size > 0 ? output : nil)
    }

    private func finish(_ s: Shortcut, _ outcome: Outcome) {
        guard outcome.ok else {
            ActivityCenter.shared.show(.notice(title: "“\(s.name)” didn't finish", detail: outcome.error ?? "The Shortcut stopped with an error",
                                               icon: "exclamationmark.triangle.fill", tone: .warning), for: 4)
            return
        }
        guard let file = outcome.output, let data = try? Data(contentsOf: file) else {
            ActivityCenter.shared.show(.notice(title: s.name, detail: "Done", icon: "square.2.layers.3d.fill"), for: 2)
            return
        }
        if NSImage(data: data) != nil {
            // A picture: on the Shelf, where it can be dragged anywhere.
            let named = file.deletingLastPathComponent().appendingPathComponent("\(s.name).png")
            if let image = NSImage(data: data), let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]), (try? png.write(to: named)) != nil {
                ShelfStore.shared.add([named])
                ActivityCenter.shared.show(.notice(title: s.name, detail: "The picture is on the Shelf", icon: "photo"), for: 3)
                return
            }
        }
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                ActivityCenter.shared.show(.notice(title: s.name, detail: "Done", icon: "square.2.layers.3d.fill"), for: 2)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
            let line = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
            ActivityCenter.shared.show(.notice(title: "\(s.name) · copied", detail: String(line.prefix(120)), icon: "doc.on.clipboard"), for: 4)
            return
        }
        // Some other kind of file: on the Shelf as it came.
        ShelfStore.shared.add([file])
        ActivityCenter.shared.show(.notice(title: s.name, detail: "The result is on the Shelf", icon: "tray.and.arrow.down"), for: 3)
    }

    // MARK: - As a Glance

    var glanceShortcuts: [Shortcut] { glance.compactMap(shortcut(id:)) }

    func isInGlance(_ s: Shortcut) -> Bool { glance.contains(s.id) }

    /// Adds a Shortcut beside the notch (pinning the Glance the first time) or takes it off.
    func toggleGlance(_ s: Shortcut) {
        if let i = glance.firstIndex(of: s.id) { glance.remove(at: i) } else if glance.count < Self.glanceLimit { glance.append(s.id) }
        updateGlanceCount()
        if glance.isEmpty { LiveActivities.shared.unpin(.shortcuts) } else { LiveActivities.shared.pin(.shortcuts) }
    }

    /// Only Shortcuts that still exist take a glyph (one deleted in the Shortcuts app drops out).
    private func updateGlanceCount() {
        let count = all.isEmpty ? glance.count : glanceShortcuts.count
        guard count != Self.glanceCount else { return }
        Self.glanceCount = count
        objectWillChange.send()
    }
}
