import AppKit
import NotchKit
import SwiftUI

/// A key combination an action answers to, as macOS writes it ("⌥⌘Q").
struct ActionKey: Equatable {
    /// The key as `charactersIgnoringModifiers` gives it, lowercased: "q", "\r" (Return), "\u{7f}" (Delete).
    let key: String
    let modifiers: NSEvent.ModifierFlags

    static func command(_ key: String, _ extra: NSEvent.ModifierFlags = []) -> ActionKey {
        ActionKey(key: key, modifiers: extra.union(.command))
    }
    static let `return` = ActionKey(key: "\r", modifiers: [])

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (["\r": "↩", "\u{7f}": "⌫"][key] ?? key.uppercased())
    }

    func matches(key typed: String, modifiers held: NSEvent.ModifierFlags) -> Bool {
        typed.lowercased() == key && held.intersection([.command, .option, .control, .shift]) == modifiers
    }
}

/// One thing that can be done to a search result: in the ⌘K list, and by its shortcut while the
/// result is highlighted.
struct ItemAction: Identifiable {
    enum After {
        /// The notch stays as it is (a copy, a Banner saying what happened).
        case stay
        /// Done with the search: the bar empties and the notch closes.
        case finish
    }

    let id: String
    let title: String
    let icon: String
    var key: ActionKey?
    /// Takes something away (to the Trash, an uninstall): only from the open list, never by its
    /// shortcut alone, and in red.
    var destructive = false
    /// Actions are listed in groups, with a line between.
    var group = 0
    /// ↩'s own action stays `.stay`: what ↩ does already closes the notch when it should.
    var after: After = .stay
    let run: @MainActor () -> Void
}

/// The actions for each kind of search result.
@MainActor
enum ItemActions {
    /// What ⌘K lists for a suggestion; empty when it has nothing beyond ↩. `primary` is what ↩ does.
    static func actions(for item: Suggestion, primary: @escaping @MainActor () -> Void) -> [ItemAction] {
        switch item {
        case .app(let app): forApp(app, primary: primary)
        case .file(let url): forFile(url, primary: primary)
        case .answer(let a): forAnswer(a, primary: primary)
        default: []
        }
    }

    // MARK: - Apps

    static func forApp(_ app: AppIndex.App, primary: @escaping @MainActor () -> Void) -> [ItemAction] {
        let url = app.url
        let bundleID = Bundle(url: url)?.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        var out = [ItemAction(id: "open", title: "Open \(app.name)", icon: "arrow.up.forward.app", key: .return, run: primary),
                   ItemAction(id: "finder", title: "Show in Finder", icon: "folder", key: .command("\r"), after: .finish) { reveal(url) }]
        if let first = running.first {
            let name = app.name
            out += [
                ItemAction(id: "hide", title: first.isHidden ? "Unhide" : "Hide", icon: first.isHidden ? "eye" : "eye.slash", key: .command("h"), group: 1) {
                    let unhide = first.isHidden
                    for app in running { _ = unhide ? app.unhide() : app.hide() }
                },
                ItemAction(id: "quit", title: "Quit", icon: "xmark.circle", key: .command("q"), group: 1) {
                    running.forEach { $0.terminate() }
                    notice("Quit \(name)", icon: "xmark.circle")
                },
                ItemAction(id: "restart", title: "Restart", icon: "arrow.clockwise", group: 1) { restart(running, url: url, name: name) },
                ItemAction(id: "forcequit", title: "Force Quit", icon: "exclamationmark.octagon", key: .command("q", .option), group: 1) {
                    running.forEach { $0.forceTerminate() }
                    notice("Force quit \(name)", icon: "exclamationmark.octagon")
                },
            ]
        }
        out.append(copyPath(url, group: 2))
        if let bundleID {
            out.append(ItemAction(id: "copyid", title: "Copy Bundle Identifier", icon: "number", group: 2) { copy(bundleID, what: "bundle identifier") })
        }
        out += [
            ItemAction(id: "info", title: "Get Info", icon: "info.circle", key: .command("i"), group: 3, after: .finish) { getInfo(url) },
            ItemAction(id: "contents", title: "Show Package Contents", icon: "shippingbox", group: 3, after: .finish) {
                NSWorkspace.shared.open(url.appendingPathComponent("Contents"))
            },
        ]
        if AppSettings.shared.toolsEnabled, !url.path.hasPrefix("/System/") {
            out.append(ItemAction(id: "uninstall", title: "Uninstall…", icon: "trash", key: .command("\u{7f}"), destructive: true, group: 4) {
                CommandCenter.shared.run([Command(action: .uninstall(url), title: "Uninstall \(app.name)…", icon: "xmark.app", verb: "Review")])
            })
        }
        return out
    }

    /// Quits, and opens it again once it has gone (apps asking to save get as long as they need, up to a minute).
    private static func restart(_ running: [NSRunningApplication], url: URL, name: String) {
        running.forEach { $0.terminate() }
        notice("Restarting \(name)", icon: "arrow.clockwise")
        Task {
            let deadline = Date().addingTimeInterval(60)
            while running.contains(where: { !$0.isTerminated }), Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
            guard running.allSatisfy(\.isTerminated) else { return }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    // MARK: - Files

    static func forFile(_ url: URL, primary: @escaping @MainActor () -> Void) -> [ItemAction] {
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        let others = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { $0 != defaultApp }.prefix(3)
        var out = [ItemAction(id: "open", title: defaultApp.map { "Open in \(appName($0))" } ?? "Open", icon: "arrow.up.forward.square",
                              key: .return, run: primary)]
        out += others.map { app in
            ItemAction(id: "with:" + app.path, title: "Open in \(appName(app))", icon: "arrow.up.forward.app", after: .finish) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init())
            }
        }
        out += [
            ItemAction(id: "finder", title: "Show in Finder", icon: "folder", key: .command("\r"), group: 1, after: .finish) { reveal(url) },
            ItemAction(id: "quicklook", title: "Quick Look", icon: "eye", key: .command("y"), group: 1) { quickLook(url) },
            ItemAction(id: "info", title: "Get Info", icon: "info.circle", key: .command("i"), group: 1, after: .finish) { getInfo(url) },
            copyPath(url, group: 2),
            ItemAction(id: "copyfile", title: "Copy File", icon: "doc.on.doc", group: 2) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
                notice("Copied \(url.lastPathComponent)", icon: "doc.on.doc")
            },
            ItemAction(id: "shelf", title: "Add to Shelf", icon: "tray.and.arrow.down", group: 3) {
                ShelfStore.shared.add([url])
                notice("Added to Shelf", icon: "tray.and.arrow.down.fill", tone: .success)
            },
            ItemAction(id: "airdrop", title: "AirDrop", icon: "airplayaudio", group: 3, after: .finish) { ShelfStore.airDrop([url]) },
            ItemAction(id: "trash", title: "Move to Trash", icon: "trash", key: .command("\u{7f}"), destructive: true, group: 4) {
                NSWorkspace.shared.recycle([url]) { _, error in
                    Task { @MainActor in
                        if error != nil {
                            notice("Couldn't move it to the Trash", icon: "trash.slash", tone: .warning)
                        } else {
                            notice("Moved \(url.lastPathComponent) to the Trash", icon: "trash")
                            SearchSuggestions.shared.refresh()
                        }
                    }
                }
            },
        ]
        return out
    }

    // MARK: - Answers

    static func forAnswer(_ answer: QuickAnswers.Answer, primary: @escaping @MainActor () -> Void) -> [ItemAction] {
        var out = [ItemAction(id: "copy", title: "Copy \(answer.copyValue)", icon: "doc.on.doc", key: .return, run: primary)]
        if let app = FrontmostTracker.shared.userApp, let name = app.localizedName {
            out.append(ItemAction(id: "paste", title: "Paste into \(name)", icon: "doc.on.clipboard", after: .finish) {
                TextInsertion.insert(answer.copyValue)
            })
        }
        return out
    }

    // MARK: - Shared

    private static func copyPath(_ url: URL, group: Int) -> ItemAction {
        ItemAction(id: "copypath", title: "Copy Path", icon: "link", key: .command("c", .shift), group: group) {
            copy(url.path, what: "path")
        }
    }

    private static func copy(_ text: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice("Copied \(what)", icon: "doc.on.doc")
    }

    /// Previews the file full size, or closes the preview. With the other files in the list
    /// alongside, so the arrow keys step through them.
    private static func quickLook(_ url: URL) {
        let quickLook = QuickLook.shared
        if quickLook.isVisible { return quickLook.close() }
        let files = SearchSuggestions.shared.items.compactMap { if case .file(let u) = $0 { u } else { nil } }
        if let i = files.firstIndex(of: url) { quickLook.show(files, at: i) } else { quickLook.show([url], at: 0) }
    }

    private static func reveal(_ url: URL) {
        QuickLook.shared.close()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Finder's Get Info window (needs permission to control Finder, asked the first time).
    private static func getInfo(_ url: URL) {
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(path)" as alias)
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if error != nil {
                Task { @MainActor in notice("Couldn't open Get Info", detail: "Allow NotchApp to control Finder", icon: "info.circle", tone: .warning) }
            }
        }
    }

    private static func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func notice(_ title: String, detail: String = "", icon: String, tone: NoticeTone = .info) {
        ActivityCenter.shared.show(.notice(title: title, detail: detail, icon: icon, tone: tone), for: 2)
    }
}

/// The ⌘K list over the search results: which result it's for, its actions, and the filter typed
/// into it. `AskView` attaches what's highlighted and what ↩ does while it's on screen.
@MainActor
final class ActionPanel: ObservableObject {
    static let shared = ActionPanel()

    struct Target {
        let title: String
        let icon: NSImage?
    }

    @Published private(set) var target: Target?
    @Published private(set) var actions: [ItemAction] = []
    @Published var filter = "" { didSet { selected = 0 } }
    @Published var selected = 0

    var isOpen: Bool { target != nil }

    /// The highlighted result and what ↩ does to it, while the Search tab shows suggestions.
    private var source: (current: () -> Suggestion?, primary: (Suggestion) -> Void, finish: () -> Void)?

    func attach(current: @escaping () -> Suggestion?, primary: @escaping (Suggestion) -> Void, finish: @escaping () -> Void) {
        source = (current, primary, finish)
    }

    func detach() {
        source = nil
        close()
    }

    /// The actions that match the filter, in their groups.
    var shown: [ItemAction] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return actions }
        return actions.filter { $0.title.localizedCaseInsensitiveContains(q) || FuzzyMatch.score($0.title, q) >= 60 }
    }

    func toggle() -> Bool {
        if isOpen { close(); return true }
        guard let item = source?.current() else { return false }
        let list = actions(for: item)
        guard list.count > 1 else { return false }
        filter = ""
        selected = 0
        actions = list
        target = Self.target(for: item)
        AssistantStore.shared.actionsOpen = true
        return true
    }

    func close() {
        guard isOpen else { return }
        target = nil
        actions = []
        filter = ""
        AssistantStore.shared.actionsOpen = false
    }

    /// Counts the arrow-key moves, for the list to keep the highlight in view (but not hovering).
    @Published private(set) var moves = 0

    func move(_ delta: Int) {
        let count = shown.count
        guard count > 0 else { return }
        selected = min(max(selected + delta, 0), count - 1)
        moves += 1
    }

    func runSelected() {
        let list = shown
        guard list.indices.contains(selected) else { return }
        run(list[selected])
    }

    func run(_ action: ItemAction) {
        close()
        action.run()
        if action.after == .finish { source?.finish() }
    }

    /// A key with ⌘ (or another modifier) while the Search tab is up: ⌘K opens or closes the
    /// list; an action's shortcut runs it, list open or not (taking something away only from the
    /// open list). False when it isn't one of these, so the key goes on as usual.
    func handle(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let held = modifiers.intersection([.command, .option, .control, .shift])
        guard !held.isEmpty else { return false }
        if held == .command, key.lowercased() == "k" { return toggle() }
        let list = isOpen ? actions : source?.current().map(actions(for:)) ?? []
        guard let action = list.first(where: { $0.key?.matches(key: key, modifiers: held) == true }),
              isOpen || !action.destructive else { return false }
        run(action)
        return true
    }

    private func actions(for item: Suggestion) -> [ItemAction] {
        guard let source else { return [] }
        return ItemActions.actions(for: item) { source.primary(item) }
    }

    private static func target(for item: Suggestion) -> Target {
        switch item {
        case .app(let app): Target(title: app.name, icon: NSWorkspace.shared.icon(forFile: app.url.path))
        case .file(let url): Target(title: url.lastPathComponent, icon: NSWorkspace.shared.icon(forFile: url.path))
        case .answer(let a): Target(title: a.title, icon: nil)
        default: Target(title: "", icon: nil)
        }
    }
}
