import AppKit
import ApplicationServices

/// The menus of the app in front, searchable from the command bar ("export pdf" → File › Export
/// as PDF…). Read through Accessibility in the background as the notch opens, so typing finds
/// them at once; pressing one runs it in that app.
@MainActor
final class MenuSearch {
    static let shared = MenuSearch()

    struct Item: @unchecked Sendable {
        let title: String
        /// The menus above it: ["File", "Export To"].
        let path: [String]
        let shortcut: String?
        let element: AXUIElement
        var searchText: String { (path + [title]).joined(separator: " ").lowercased() }
    }

    /// Wraps a menu item for a command (commands compare by value; this compares by identity).
    final class Ref: Equatable, @unchecked Sendable {
        let item: Item
        let appName: String
        init(_ item: Item, appName: String) { self.item = item; self.appName = appName }
        static func == (a: Ref, b: Ref) -> Bool { a === b }
    }

    private var cache: (pid: pid_t, appName: String, at: Date, items: [Item])?
    private var loading: pid_t?

    /// Reads the menus of the app in front, unless they were read a moment ago.
    func prepare() {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication ?? FrontmostTracker.shared.lastOther,
              app.processIdentifier != getpid() else { return }
        let pid = app.processIdentifier
        if let cache, cache.pid == pid, Date().timeIntervalSince(cache.at) < 15 { return }
        guard loading != pid else { return }
        loading = pid
        let name = app.localizedName ?? "App"
        Task.detached(priority: .userInitiated) {
            let items = Self.read(pid: pid)
            await MainActor.run {
                MenuSearch.shared.cache = (pid, name, Date(), items)
                MenuSearch.shared.loading = nil
                SearchSuggestions.shared.refresh()
                AppActions.shared.refresh()
            }
        }
    }

    /// Menu items for what's typed: every word somewhere in the item or its menus, items whose
    /// own title matches first.
    func matches(_ query: String, limit: Int) -> [Ref] {
        guard let cache else { return [] }
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let hits = cache.items.filter { item in words.allSatisfy { item.searchText.contains($0) } }
        let ranked = hits.sorted { a, b in score(a, words) > score(b, words) }
        return ranked.prefix(limit).map { Ref($0, appName: cache.appName) }
    }

    /// Titles worth offering before anything is typed, in order of how useful they tend to be.
    private static let featuredTitles = ["export as pdf", "export to pdf", "save as pdf", "export", "copy link", "share",
                                         "duplicate", "reveal in finder", "show in finder", "rename", "move to"]

    /// The app's most useful menu items (Export as PDF, Copy Link…), for the row under the empty bar.
    func featured(pid: pid_t, limit: Int) -> [Ref] {
        guard let cache, cache.pid == pid else { return [] }
        var out: [Ref] = []
        for title in Self.featuredTitles {
            if let item = cache.items.first(where: { Self.plain($0.title) == title }),
               !out.contains(where: { $0.item.title == item.title }) {
                out.append(Ref(item, appName: cache.appName))
            }
            if out.count == limit { break }
        }
        return out
    }

    /// The first of `candidates` the app's menus have, each a path ending in the item's title
    /// (["Share", "Master File"]): the title matches, and every menu named before it is above it.
    func find(pid: pid_t, _ candidates: [[String]]) -> Ref? {
        guard let cache, cache.pid == pid else { return nil }
        for candidate in candidates {
            guard let last = candidate.last.map(Self.plain) else { continue }
            let menus = candidate.dropLast().map(Self.plain)
            if let item = cache.items.first(where: { item in
                Self.plain(item.title) == last && menus.allSatisfy { m in item.path.contains { Self.plain($0) == m } }
            }) {
                return Ref(item, appName: cache.appName)
            }
        }
        return nil
    }

    private static func plain(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func score(_ item: Item, _ words: [String]) -> Int {
        let title = item.title.lowercased()
        var s = 0
        if title.hasPrefix(words[0]) { s += 4 }
        s += words.filter { title.contains($0) }.count * 2
        s -= item.path.count
        return s
    }

    /// Clicks the item (the app keeps the focus it had: the notch never takes it over).
    static func press(_ ref: Ref) {
        NotchPresenter.shared.primary?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AXUIElementPerformAction(ref.item.element, kAXPressAction as CFString)
        }
    }

    // MARK: - Reading

    private nonisolated static func read(pid: pid_t) -> [Item] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar: AXUIElement = value(app, kAXMenuBarAttribute),
              let menus: [AXUIElement] = value(bar, kAXChildrenAttribute) else { return [] }
        var items: [Item] = []
        let deadline = Date().addingTimeInterval(1.2)
        // The first menu is the Apple menu: system things, not the app's.
        for menu in menus.dropFirst() {
            guard let title: String = value(menu, kAXTitleAttribute), !title.isEmpty else { continue }
            walk(menu, path: [title], depth: 0, into: &items, deadline: deadline)
            if items.count > 2000 || Date() > deadline { break }
        }
        return items
    }

    private nonisolated static func walk(_ element: AXUIElement, path: [String], depth: Int, into items: inout [Item], deadline: Date) {
        guard depth < 4, Date() < deadline,
              let children: [AXUIElement] = value(element, kAXChildrenAttribute) else { return }
        for child in children {
            let role: String = value(child, kAXRoleAttribute) ?? ""
            if role == "AXMenu" {
                walk(child, path: path, depth: depth + 1, into: &items, deadline: deadline)
                continue
            }
            guard role == "AXMenuItem", let title: String = value(child, kAXTitleAttribute), !title.isEmpty else { continue }
            let submenu: [AXUIElement]? = value(child, kAXChildrenAttribute)
            if let submenu, !submenu.isEmpty {
                walk(child, path: path + [title], depth: depth + 1, into: &items, deadline: deadline)
            } else if (value(child, kAXEnabledAttribute) as Bool?) ?? true {
                items.append(Item(title: title, path: path, shortcut: shortcut(child), element: child))
            }
        }
    }

    /// "⇧⌘E" from the item's key equivalent.
    private nonisolated static func shortcut(_ item: AXUIElement) -> String? {
        guard let key: String = value(item, kAXMenuItemCmdCharAttribute), !key.isEmpty else { return nil }
        let mods: Int = value(item, kAXMenuItemCmdModifiersAttribute) ?? 0
        var s = ""
        if mods & 4 != 0 { s += "⌃" }
        if mods & 2 != 0 { s += "⌥" }
        if mods & 1 != 0 { s += "⇧" }
        if mods & 8 == 0 { s += "⌘" }
        return s + key.uppercased()
    }

    private nonisolated static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success, let ref else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return (ref as! AXUIElement) as? T
        }
        if T.self == [AXUIElement].self { return (ref as? [AXUIElement]) as? T }
        return ref as? T
    }
}
