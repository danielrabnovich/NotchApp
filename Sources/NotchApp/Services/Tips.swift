import AppKit

/// Tips that show up when they'd help: after you've done something the long way a few times, one
/// Banner says the short way. Each tip shows once, at most one a day, never in a call or over a
/// full-screen app (Banners wait for those), and not in NotchApp's first day. And after an
/// update, a Prompt with what's new.
@MainActor
final class Tips {
    static let shared = Tips()

    enum Event {
        /// A tab picked from the open notch's tab bar.
        case tabPicked(NotchTab)
        /// A tab opened by its shortcut.
        case tabShortcut(NotchTab)
        case glanceClicked, glanceHeld
        case shelfDrop, trayShaken
        case copied, clipboardOpened
    }

    private enum Tip: String {
        case holdGlance, shakeTray, clipboard
        case tabShortcut // one per tab, as "tabShortcut.<tab>"
    }

    private let defaults = UserDefaults.standard
    private var counts: [String: Int] {
        get { defaults.dictionary(forKey: "tips.counts") as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: "tips.counts") }
    }
    private var shown: Set<String> {
        get { Set(defaults.stringArray(forKey: "tips.shown") ?? []) }
        set { defaults.set(Array(newValue), forKey: "tips.shown") }
    }
    private var waiting: DispatchWorkItem?

    func start() {
        if defaults.object(forKey: "tips.since") == nil { defaults.set(Date(), forKey: "tips.since") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.showWhatsNew() }
    }

    func note(_ event: Event) {
        switch event {
        case .tabPicked(let tab):
            guard let action = Self.shortcut(for: tab), HotKeys.combo(for: action) != nil else { return }
            if bump("tab.\(tab.rawValue)") >= 6, (counts["tabKey.\(tab.rawValue)"] ?? 0) == 0 { offer("tabShortcut.\(tab.rawValue)") }
        case .tabShortcut(let tab):
            bump("tabKey.\(tab.rawValue)")
        case .glanceClicked:
            if bump("glanceClick") >= 8, (counts["glanceHold"] ?? 0) == 0 { offer(Tip.holdGlance.rawValue) }
        case .glanceHeld:
            bump("glanceHold")
        case .shelfDrop:
            guard AppSettings.shared.shakeTray else { return }
            if bump("shelfDrop") >= 5, (counts["shake"] ?? 0) == 0 { offer(Tip.shakeTray.rawValue) }
        case .trayShaken:
            bump("shake")
        case .copied:
            guard AppSettings.shared.clipboardHistory else { return }
            if bump("copy") >= 25, (counts["clipboardOpened"] ?? 0) == 0 { offer(Tip.clipboard.rawValue) }
        case .clipboardOpened:
            bump("clipboardOpened")
        }
    }

    @discardableResult
    private func bump(_ key: String) -> Int {
        var c = counts
        // Past what any tip waits for, there's nothing more to count.
        guard (c[key] ?? 0) < 50 else { return 50 }
        c[key, default: 0] += 1
        counts = c
        return c[key]!
    }

    // MARK: - Showing one

    private func offer(_ id: String) {
        guard !shown.contains(id), waiting == nil, let text = text(for: id) else { return }
        if let since = defaults.object(forKey: "tips.since") as? Date, Date().timeIntervalSince(since) < 24 * 3600 { return }
        if let last = defaults.object(forKey: "tips.last") as? Date, Calendar.current.isDateInToday(last) { return }
        attempt(id, text, tries: 0)
    }

    /// Once the notch is closed and quiet (a tip found while it's open shows after), for up to a few minutes.
    private func attempt(_ id: String, _ text: (title: String, detail: String), tries: Int) {
        waiting = nil
        guard tries < 40 else { return }
        let quiet = !NotchPresenter.shared.isBusy && ActivityCenter.shared.banner == nil && MeetingMonitor.shared.call == nil
        guard quiet else {
            let work = DispatchWorkItem { [weak self] in self?.attempt(id, text, tries: tries + 1) }
            waiting = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            return
        }
        shown.insert(id)
        defaults.set(Date(), forKey: "tips.last")
        ActivityCenter.shared.show(.notice(title: text.title, detail: text.detail, icon: "lightbulb.fill", tone: .info), for: 7)
    }

    private func text(for id: String) -> (title: String, detail: String)? {
        if id.hasPrefix("tabShortcut.") {
            guard let tab = NotchTab(rawValue: String(id.dropFirst("tabShortcut.".count))), let action = Self.shortcut(for: tab),
                  let combo = HotKeys.combo(for: action), AppSettings.shared.hotKeysEnabled else { return nil }
            return ("Tip: \(combo.display) opens \(tab.title)", "From any app, without reaching for the notch")
        }
        switch Tip(rawValue: id) {
        case .holdGlance: return ("Tip: hold a Glance", "Press and hold one beside the notch to open its details")
        case .shakeTray: return ("Tip: shake a file as you drag it", "A tray drops in at the pointer, wherever you are")
        case .clipboard:
            let key = HotKeys.combo(for: .clipboard).map { " (\($0.display))" } ?? ""
            return ("Tip: what you copy is kept", "Shelf › Clipboard has your recent copies\(key)")
        default: return nil
        }
    }

    private static func shortcut(for tab: NotchTab) -> HotKeys.Action? {
        switch tab {
        case .ask: .search
        case .home: .home
        case .shelf: .shelf
        case .tasks: .tasks
        case .timer: .timer
        case .mixer: .mixer
        case .controls: .controls
        case .stats: .stats
        case .tools: .tools
        case .agents: .agents
        }
    }

    // MARK: - What's new

    /// Kept by the updater just before it swaps the new copy in.
    static func rememberRelease(version: String, notes: String, page: URL?) {
        UserDefaults.standard.set(["version": version, "notes": notes, "page": page?.absoluteString ?? ""], forKey: "whatsNew")
    }

    /// The first launch of an update installed from the notch: its headline, and the full notes a click away.
    private func showWhatsNew() {
        guard let saved = defaults.dictionary(forKey: "whatsNew") as? [String: String], let version = saved["version"] else { return }
        // Shown once, and only by the version it's about (an update that didn't take is skipped).
        defaults.removeObject(forKey: "whatsNew")
        guard version == AppUpdater.currentVersion else { return }
        let lines = (saved["notes"] ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let headline = lines.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*- ")) } ?? "NotchApp was updated"
        let page = saved["page"].flatMap { URL(string: $0) }
        NotchPresenter.shared.offer(Prompt(icon: "sparkles", tint: .systemPurple, title: "New in NotchApp \(version)", detail: headline,
                                           actions: page.map { url in [.init(title: "See What's New", primary: true) { NSWorkspace.shared.open(url) }] } ?? [],
                                           dismissTitle: "OK"))
    }
}
