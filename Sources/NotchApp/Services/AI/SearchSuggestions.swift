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

    var id: String {
        switch self {
        case .answer(let a): "answer:\(a.title)"
        case .app(let a): "app:\(a.id)"
        case .file(let u): "file:\(u.path)"
        case .search(let q): "search:\(q)"
        case .command(let c): "command:\(c.title)"
        case .plan(let q): "plan:\(q)"
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
    private var fileTask: Task<Void, Never>?
    private var query = ""

    func update(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        query = q
        fileTask?.cancel()
        guard !q.isEmpty else { set([]); return }
        AppIndex.shared.refreshIfNeeded()

        // Commands ("task …", "note …", "timer 10m") lead; the "/" list shows nothing else.
        let commands = CommandParser.parse(q)
        if !commands.isEmpty, commands.allSatisfy({ if case .template = $0.action { true } else { false } }) {
            set(commands.map { .command($0) })
            return
        }
        let acts = commands.contains { if case .show = $0.action { false } else if case .settings = $0.action { false } else { true } }

        var head: [Suggestion] = commands.map { .command($0) }
        // With a model, "plan a trip to Lisbon" or "remind me to … and …" can become a set of actions.
        if AssistantStore.shared.aiAvailable, CommandPlanner.looksLikeRequest(q) { head.append(.plan(q)) }
        if let answer = QuickAnswers.answer(q) { head.append(.answer(answer)) }
        let (appQuery, explicit) = AppIndex.stripLaunchPrefix(q)
        let apps = AppIndex.shared.search(appQuery, limit: explicit ? 3 : 2)
        // A strong app match goes first; otherwise the full search does.
        let strong = apps.first.map { explicit || ($0.score >= 85 && !q.contains(" ")) } ?? false
        if strong, let top = apps.first { head.append(.app(top.app)) }
        head.append(.search(q))
        head += apps.dropFirst(strong ? 1 : 0).filter { explicit || $0.score >= 60 }.map { .app($0.app) }
        set(Array(head.prefix(6)))

        // File names, after a short pause so every keystroke doesn't hit Spotlight.
        guard q.count >= 3, !acts, QuickAnswers.answer(q) == nil else { return }
        fileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            await FolderAccess.shared.ensure()
            let files = await Task.detached { FileFinder.quickMatches(q, limit: 3) }.value
            guard !Task.isCancelled, let self, self.query == q else { return }
            self.set(Array((head + files.map { .file($0) }).prefix(6)))
        }
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }

    var current: Suggestion? { items.indices.contains(selected) ? items[selected] : nil }

    func clear() {
        fileTask?.cancel()
        query = ""
        set([])
    }

    private func set(_ new: [Suggestion]) {
        let keep = current
        items = new
        // Keep the highlight on the same item when the list refines; otherwise the top one.
        selected = keep.flatMap { k in new.firstIndex(of: k) } ?? 0
        AssistantStore.shared.suggesting = !new.isEmpty
    }
}
