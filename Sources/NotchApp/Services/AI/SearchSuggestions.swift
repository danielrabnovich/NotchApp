import AppKit
import SwiftUI

/// What the search bar offers while you type, before pressing Return.
enum Suggestion: Identifiable, Equatable {
    case answer(QuickAnswers.Answer)
    case app(AppIndex.App)
    case file(URL)
    case search(String)
    case command(Command)
    /// Hand the request to the model to turn into tasks, notes or timers.
    case plan(String)
    /// Carry out an instruction in the app in front ("export this as a PDF").
    case doInApp(String, app: String)

    var id: String {
        switch self {
        case .answer(let a): "answer:\(a.title)"
        case .app(let a): "app:\(a.id)"
        case .file(let u): "file:\(u.path)"
        case .search(let q): "search:\(q)"
        case .command(let c): "command:\(c.title)"
        case .plan(let q): "plan:\(q)"
        case .doInApp(let q, _): "app:do:\(q)"
        }
    }
}

/// Builds the live list: an instant answer, matching apps, files whose names match, and
/// "Search for …" (the full search, with AI when a model is ready).
@MainActor
final class SearchSuggestions: ObservableObject {
    static let shared = SearchSuggestions()

    @Published private(set) var items: [Suggestion] = []
    @Published var selected = 0
    /// File matches are on their way: the list holds placeholder rows for them so they don't pop in.
    @Published private(set) var loadingFiles = false
    private var fileTask: Task<Void, Never>?

    /// Rows the list shows at most before it scrolls.
    static let maxRows = 5
    /// Placeholder rows held while file matches load. Files and screenshots can fill the list, so
    /// hold all of it: when fewer arrive the list shrinks, which reads better than rows popping in.
    var placeholderRows: Int { loadingFiles ? max(0, Self.maxRows - items.count) : 0 }
    private var query = ""
    var currentQuery: String { query }

    func update(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        query = q
        fileTask?.cancel()
        loadingFiles = false
        guard !q.isEmpty else { set([]); return }
        AppIndex.shared.refreshIfNeeded()
        // A search may look for pictures by description: have MobileCLIP loaded by the time it runs.
        if q.count >= 3 { VisualSearch.prewarm() }

        // Commands ("task …", "note …", "timer 10m") lead; the "/" list shows nothing else.
        let commands = CommandParser.parse(q)
        if !commands.isEmpty, commands.allSatisfy({ if case .template = $0.action { true } else { false } }) {
            set(commands.map { .command($0) })
            return
        }
        let acts = commands.contains { if case .show = $0.action { false } else if case .settings = $0.action { false } else { true } }

        // Settings: "turn off haptics" / "settings glances" lead; a plain "haptics" offers them after search.
        let (settingRows, explicitSettings) = PaletteCommands.settings(q)
        if explicitSettings, !settingRows.isEmpty {
            set(settingRows.map { .command($0) })
            return
        }
        // AI Commands: "ai …" lists them; a command's name on its own offers it.
        let (aiCommands, explicitAI) = AICommandStore.shared.matches(q)
        let aiRows = aiCommands.map { c in
            Command(action: .aiCommand(c.id), title: c.name,
                    subtitle: c.output == .replace ? "Replaces the selected text" : "On the selected text",
                    icon: c.icon, verb: c.output == .replace ? "Replace" : "Run")
        }
        if explicitAI {
            set(aiRows.map { .command($0) })
            return
        }
        // Menus of the app in front: "menu …" searches them all; otherwise a couple of close ones.
        MenuSearch.shared.prepare()
        let explicitMenu = q.lowercased().hasPrefix("menu ")
        let menuQuery = explicitMenu ? String(q.dropFirst(5)) : q
        let menuRows = (explicitMenu || q.count >= 3) ? MenuSearch.shared.matches(menuQuery, limit: explicitMenu ? 6 : 2).map { ref in
            Command(action: .menuItem(ref), title: ref.item.title,
                    subtitle: ([ref.appName] + ref.item.path).joined(separator: " › ") + (ref.item.shortcut.map { "  \($0)" } ?? ""),
                    icon: "filemenu.and.selection", verb: "Run")
        } : []
        if explicitMenu {
            set(menuRows.map { .command($0) })
            return
        }
        // Shortcuts from the Shortcuts app: "shortcut …" lists them; a name (or "run …") offers it.
        let shortcuts = ShortcutsApp.shared
        shortcuts.refreshIfStale()
        let lowerQ = q.lowercased()
        if let prefix = ["shortcuts", "shortcut"].first(where: { lowerQ == $0 || lowerQ.hasPrefix($0 + " ") }) {
            let rows = shortcuts.matches(String(q.dropFirst(prefix.count)), limit: 6).map { shortcuts.command($0, context: AppActions.shared.context) }
            set(rows.isEmpty ? [.command(Command(action: .openURL(URL(string: "shortcuts://")!), title: "No Shortcut matches",
                                                 subtitle: "Open the Shortcuts app", icon: "square.2.layers.3d", verb: "Open"))]
                             : rows.map { .command($0) })
            return
        }

        var head: [Suggestion] = commands.map { .command($0) }
        // "export this as pdf" with an app in front: do it there.
        if AssistantStore.shared.aiAvailable, AppDo.looksLikeInstruction(q), let app = AppActions.shared.context?.appName {
            head.append(.doInApp(q, app: app))
        }
        // What fits the app in front ("summ" in Safari → Summarize page).
        head += AppActions.shared.matches(q, limit: 2).map { .command($0) }
        // With a model, "plan a trip to Lisbon" or "remind me to … and …" can become a set of actions.
        if AssistantStore.shared.aiAvailable, CommandPlanner.looksLikeRequest(q) { head.append(.plan(q)) }
        let answer = QuickAnswers.answer(q)
        if let answer { head.append(.answer(answer)) }
        let (appQuery, explicit) = AppIndex.stripLaunchPrefix(q)
        let apps = AppIndex.shared.search(appQuery, limit: explicit ? 3 : 2)
        // A Shortcut whose name starts with what's typed leads, like a strong app match.
        let shortcutHits = appQuery.count >= 3 ? shortcuts.matches(appQuery, limit: 2) : []
        let leading = shortcutHits.filter { $0.name.lowercased().hasPrefix(appQuery.lowercased()) }
        head += leading.map { .command(shortcuts.command($0, context: AppActions.shared.context)) }
        // A strong app match goes first; otherwise the full search does.
        let strong = apps.first.map { explicit || ($0.score >= 85 && !q.contains(" ")) } ?? false
        if strong, let top = apps.first { head.append(.app(top.app)) }
        head.append(.search(q))
        head += shortcutHits.filter { !leading.contains($0) }.prefix(1).map { .command(shortcuts.command($0, context: AppActions.shared.context)) }
        head += aiRows.prefix(2).map { .command($0) }
        head += settingRows.prefix(2).map { .command($0) }
        head += menuRows.map { .command($0) }
        head += apps.dropFirst(strong ? 1 : 0).filter { explicit || $0.score >= 60 }.map { .app($0.app) }
        set(Array(head.prefix(6)))

        // File names, after a short pause so every keystroke doesn't hit Spotlight.
        guard q.count >= 3, !acts, answer == nil else { return }
        loadingFiles = true
        publishRows()
        fileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            await FolderAccess.shared.ensure()
            let files = await Task.detached { FileFinder.quickMatches(q, limit: 3) }.value
            guard !Task.isCancelled, let self, self.query == q else { return }
            // Screenshots whose text matches, read on this Mac.
            let shots = AppSettings.shared.screenshotSearch ? ScreenshotText.shared.search(q, limit: 2).filter { !files.contains($0) } : []
            self.loadingFiles = false
            self.set(Self.withFiles(head, files.map { .file($0) } + shots.map { .file($0) }))
        }
    }

    /// The list with the files that matched. Up to two files always get in: the end of the list
    /// (menu items, settings, apps that matched less well) gives way for them, but never "Search
    /// for …". On a common word the rows above used to fill the list, and no file showed at all.
    static func withFiles(_ head: [Suggestion], _ files: [Suggestion], rows: Int = 6) -> [Suggestion] {
        guard !files.isEmpty else { return Array(head.prefix(rows)) }
        var kept = Array(head.prefix(max(0, rows - min(files.count, 2))))
        if let search = head.first(where: { if case .search = $0 { true } else { false } }), !kept.contains(search), !kept.isEmpty {
            kept[kept.count - 1] = search
        }
        return Array((kept + files).prefix(rows))
    }

    /// Re-runs the current query, for results that arrive later (a port lookup).
    func refresh() {
        guard !query.isEmpty else { return }
        let keep = selected
        update(query)
        selected = min(keep, max(items.count - 1, 0))
    }

    /// Stops at the first and last row, as results do (and Spotlight): wrapping round made ↓ at
    /// the bottom jump back to the top, away from where you were looking.
    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = min(max(selected + delta, 0), items.count - 1)
    }

    var current: Suggestion? { items.indices.contains(selected) ? items[selected] : nil }

    func clear() {
        fileTask?.cancel()
        loadingFiles = false
        query = ""
        set([])
    }

    private func set(_ new: [Suggestion]) {
        let keep = current
        items = new
        // Keep the highlight on the same item when the list refines; otherwise the top one.
        selected = keep.flatMap { k in new.firstIndex(of: k) } ?? 0
        AssistantStore.shared.suggesting = !new.isEmpty
        publishRows()
    }

    private func publishRows() {
        let rows = min(items.count + placeholderRows, Self.maxRows)
        if AssistantStore.shared.suggestionRows != rows { AssistantStore.shared.suggestionRows = rows }
    }
}
