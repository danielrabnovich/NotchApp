import AppKit
import ApplicationServices
import SwiftUI

/// Notifications in the notch, with a reply. macOS doesn't let apps read other apps'
/// notifications, but its banners are on screen for Accessibility: each one is read as it
/// appears, shown as a Banner under the notch, and the system's own banner is moved out of sight
/// while it lives on, so its Reply box can still take your answer. Messages can also be answered
/// through Messages itself, after the banner has gone.
@MainActor
final class NotificationMirror: ObservableObject {
    static let shared = NotificationMirror()

    struct Item: Identifiable, Equatable {
        /// The banner's own identifier.
        let id: String
        let app: String
        let bundleID: String?
        let title: String
        let subtitle: String
        let body: String
        let date: Date
        /// The banner offered a reply box.
        var canReply: Bool

        var sender: String { title.isEmpty ? app : title }
        var text: String { [subtitle, body].filter { !$0.isEmpty }.joined(separator: " · ") }
        var isMessages: Bool { bundleID == "com.apple.MobileSMS" }
        /// A reply can be sent: through the banner while it's up, or through Messages.
        var replyable: Bool { canReply || isMessages }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case off, chats, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: "Off"
            case .chats: "Chats"
            case .all: "All Apps"
            }
        }
    }

    /// The latest ones, newest first, for replying after the Banner has gone.
    @Published private(set) var recent: [Item] = []

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var poll: Timer?
    private var seen: Set<String> = []
    /// Banners from apps the notch doesn't show: while one is up, the system's banners stay in view.
    private var foreignIDs: Set<String> = []
    /// Live system banners by identifier, for replying, opening and closing them.
    private var banners: [String: AXUIElement] = [:]
    /// Banners shown in the notch and still up: only while one is does Notification Center's window
    /// go out of sight (the right-edge pane lives in the same window).
    private var mirroring: Set<String> = []
    /// New banners waiting a beat before they count: the pane's items appear a moment before its
    /// list does, and would otherwise pass for banners (and hide the pane as it opens).
    private var arriving: [String: Date] = [:]
    /// The pane was open at the last look: it stays so until its notifications have all gone.
    private var paneShown = false
    private var launchWatch: Any?
    /// A look once a second as well, in case Notification Center doesn't announce a new banner.
    private var heartbeat: Timer?
    /// Waiting for Accessibility to be allowed.
    private var accessWait: Timer?

    // MARK: - Watching

    func apply() {
        stop()
        guard AppSettings.shared.notificationMirror != .off else { return }
        guard AXIsProcessTrusted() else {
            // Granted later (or again, after a rebuild resets it): start then, not at the next launch.
            DebugHooks.log("NotificationMirror: needs Accessibility; starts once it's allowed")
            let wait = Timer(timeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    NotificationMirror.shared.apply()
                }
            }
            wait.tolerance = 0.5
            RunLoop.main.add(wait, forMode: .common)
            accessWait = wait
            return
        }
        attach()
        let beat = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let mirror = NotificationMirror.shared
                if mirror.poll == nil { mirror.scan() }
            }
        }
        beat.tolerance = 0.3
        RunLoop.main.add(beat, forMode: .common)
        heartbeat = beat
        // Notification Center restarts now and then (and after a crash): follow it.
        launchWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                                       object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.centerID else { return }
            MainActor.assumeIsolated { NotificationMirror.shared.attach() }
        }
    }

    private func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        observedPID = 0
        poll?.invalidate()
        poll = nil
        heartbeat?.invalidate()
        heartbeat = nil
        accessWait?.invalidate()
        accessWait = nil
        if let launchWatch { NSWorkspace.shared.notificationCenter.removeObserver(launchWatch) }
        launchWatch = nil
    }

    private static let centerID = "com.apple.notificationcenterui"

    private func attach() {
        guard let center = NSRunningApplication.runningApplications(withBundleIdentifier: Self.centerID).first else { return }
        let pid = center.processIdentifier
        guard pid != observedPID else { return }
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in
            MainActor.assumeIsolated { NotificationMirror.shared.scan() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // A banner arrives in a new window, or in the one already up for another banner.
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observedPID = pid
        DebugHooks.log("NotificationMirror: watching Notification Center (pid \(pid))")
    }

    /// Reads the banners up now: new ones become Banners in the notch.
    func scan() {
        guard observedPID != 0 else { return }
        let app = AXUIElementCreateApplication(observedPID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let windows: [AXUIElement] = AXReader.value(app, kAXWindowsAttribute) ?? []
        var live: [String: AXUIElement] = [:]
        var fresh: [Item] = []
        var paneOpen = false
        var waiting = false
        let now = Date()
        for window in windows {
            // The pane from the right edge lists notifications in the same window, looking just
            // like banners: they aren't new, and the pane must stay where it is.
            let pane = Self.isPane(window)
            paneOpen = paneOpen || pane
            for banner in Self.banners(in: window) {
                guard let id: String = AXReader.value(banner, kAXIdentifierAttribute) else { continue }
                live[id] = banner
                guard !seen.contains(id), !pane, !paneShown else { seen.insert(id); continue }
                guard let first = arriving[id] else { arriving[id] = now; waiting = true; continue }
                guard now.timeIntervalSince(first) >= 0.12 else { waiting = true; continue }
                seen.insert(id)
                arriving[id] = nil
                guard let item = Self.read(banner, id: id) else { continue }
                if accepts(item) { fresh.append(item) } else { foreignIDs.insert(id) }
            }
        }
        banners = live
        if paneOpen {
            // What was waiting belonged to the pane, and banners up now are in it too.
            seen.formUnion(arriving.keys)
            arriving = [:]
            mirroring = []
            fresh = []
            waiting = false
        }
        paneShown = paneOpen || (paneShown && !live.isEmpty)
        seen.formIntersection(Set(live.keys).union(recent.map(\.id)))
        foreignIDs.formIntersection(live.keys)
        arriving = arriving.filter { live[$0.key] != nil }
        mirroring.formUnion(fresh.map(\.id))
        mirroring.formIntersection(live.keys)
        if waiting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                MainActor.assumeIsolated { NotificationMirror.shared.scan() }
            }
        }
        // Keep looking while banners are up (more can stack, and they come and go).
        if live.isEmpty {
            poll?.invalidate()
            poll = nil
        } else if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                MainActor.assumeIsolated { NotificationMirror.shared.scan() }
            }
        }
        // Out of sight (again, each look: a new banner can bring the window back) while a banner of
        // ours is up, unless one up isn't ours to show: then the system shows them all.
        if !mirroring.isEmpty, foreignIDs.isEmpty, !paneShown {
            windows.forEach(Self.hide)
            if !fresh.isEmpty { DebugHooks.log("NotificationMirror: hid \(fresh.count) at \(Date().timeIntervalSince1970)") }
        }
        for item in fresh { show(item) }
    }

    private func accepts(_ item: Item) -> Bool {
        if item.bundleID == Bundle.main.bundleIdentifier { return false }
        switch AppSettings.shared.notificationMirror {
        case .off: return false
        case .all: return true
        case .chats: return AppContext.kind(of: item.bundleID) == .chat || item.isMessages
        }
    }

    private func show(_ item: Item) {
        DebugHooks.log("NotificationMirror: \(item.app) · \(item.sender) reply=\(item.canReply)")
        recent.removeAll { $0.id == item.id }
        recent.insert(item, at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
        ActivityCenter.shared.show(.message(id: item.id, app: item.app, bundleID: item.bundleID, sender: item.sender,
                                            text: item.text, replyable: item.replyable), for: 6)
    }

    // MARK: - Reading a banner

    /// The banner groups in a Notification Center window (a few levels down).
    private static func banners(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 8 else { return [] }
        let sub: String? = AXReader.value(element, kAXSubroleAttribute)
        if sub == "AXNotificationCenterBanner" || sub == "AXNotificationCenterAlert" { return [element] }
        let children: [AXUIElement] = AXReader.value(element, kAXChildrenAttribute) ?? []
        return children.flatMap { banners(in: $0, depth: depth + 1) }
    }

    /// Notification Center's pane is open: its notifications sit in a list (banners don't).
    private static func isPane(_ element: AXUIElement, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        if (AXReader.value(element, kAXIdentifierAttribute) as String?) == "AXNotificationListItems" { return true }
        let children: [AXUIElement] = AXReader.value(element, kAXChildrenAttribute) ?? []
        return children.contains { isPane($0, depth: depth + 1) }
    }

    /// "Messages, Sam, Are you around later?" with title, subtitle and body as its own texts.
    private static func read(_ banner: AXUIElement, id: String) -> Item? {
        let description: String = AXReader.value(banner, kAXDescriptionAttribute) ?? ""
        var parts: [String: String] = [:]
        for child: AXUIElement in AXReader.value(banner, kAXChildrenAttribute) ?? [] {
            guard let key: String = AXReader.value(child, kAXIdentifierAttribute),
                  let value: String = AXReader.value(child, kAXValueAttribute) else { continue }
            parts[key] = value
        }
        let title = parts["title"] ?? "", subtitle = parts["subtitle"] ?? "", body = parts["body"] ?? ""
        // The app's name comes first in the description, before the texts.
        var app = description
        for text in [title, subtitle, body] where !text.isEmpty {
            if let range = app.range(of: ", " + text) { app = String(app[..<range.lowerBound]) }
        }
        app = app.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        guard !app.isEmpty || !title.isEmpty else { return nil }
        let actions = actionNames(banner)
        DebugHooks.log("NotificationMirror: banner \(app) actions=\(actions)")
        return Item(id: id, app: app, bundleID: bundleID(forApp: app), title: title, subtitle: subtitle, body: body,
                    date: Date(), canReply: actions.contains { $0.localizedCaseInsensitiveContains("reply") })
    }

    /// Custom actions arrive as "Name:Reply\nTarget:…"; just the names.
    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return (names as? [String] ?? []).map { raw in
            raw.hasPrefix("Name:") ? String(raw.dropFirst(5).prefix { $0 != "\n" }) : raw
        }
    }

    private static func rawAction(_ element: AXUIElement, named name: String) -> String? {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return (names as? [String] ?? []).first { raw in
            let n = raw.hasPrefix("Name:") ? String(raw.dropFirst(5).prefix { $0 != "\n" }) : raw
            return n.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func bundleID(forApp name: String) -> String? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            return running.bundleIdentifier
        }
        for folder in ["/Applications", "/System/Applications", "/Applications/Utilities"] {
            let url = URL(fileURLWithPath: "\(folder)/\(name).app")
            if let id = Bundle(url: url)?.bundleIdentifier { return id }
        }
        return nil
    }

    /// Moves Notification Center's window out of sight; macOS puts it back for the next banner.
    private static func hide(_ window: AXUIElement) {
        var point = CGPoint(x: -20_000, y: -20_000)
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    // MARK: - Acting

    enum ReplyOutcome { case sent, opened }

    /// Answers a notification: in its banner's own reply box while it's up, through Messages for
    /// a message, and otherwise by opening the conversation with the reply copied, ready to paste.
    func reply(_ item: Item, text: String) async -> ReplyOutcome {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return .opened }
        if let banner = banners[item.id], await Self.replyInBanner(banner, text: reply) {
            DebugHooks.log("NotificationMirror: replied through the banner")
            return .sent
        }
        if item.isMessages, Self.replyInMessages(to: item.sender, text: reply) {
            DebugHooks.log("NotificationMirror: replied through Messages")
            return .sent
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reply, forType: .string)
        ClipboardHistory.shared.ignoreCurrent()
        open(item)
        return .opened
    }

    /// Keeps the system banner from timing out while you write (opening its reply box holds it).
    func beginReply(_ item: Item) {
        guard let banner = banners[item.id], let action = Self.rawAction(banner, named: "Reply") else { return }
        AXUIElementPerformAction(banner, action as CFString)
    }

    /// Opens what the notification is about (the conversation), as clicking the banner would.
    func open(_ item: Item) {
        if let banner = banners[item.id] {
            if let show = Self.rawAction(banner, named: "Show") {
                AXUIElementPerformAction(banner, show as CFString)
                return
            }
            if AXUIElementPerformAction(banner, kAXPressAction as CFString) == .success { return }
        }
        if let id = item.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func dismiss(_ item: Item) {
        recent.removeAll { $0.id == item.id }
        guard let banner = banners[item.id], let close = Self.rawAction(banner, named: "Close") else { return }
        AXUIElementPerformAction(banner, close as CFString)
    }

    func item(_ id: String) -> Item? { recent.first { $0.id == id } }

    /// The banner's Reply opens a text box in it: type into that and send.
    private static func replyInBanner(_ banner: AXUIElement, text: String) async -> Bool {
        var field = textField(in: banner)
        if field == nil, let action = rawAction(banner, named: "Reply") {
            AXUIElementPerformAction(banner, action as CFString)
            for _ in 0..<10 where field == nil {
                try? await Task.sleep(for: .milliseconds(80))
                field = textField(in: banner)
            }
        }
        guard let field else {
            DebugHooks.log("NotificationMirror: no reply box; actions=\(actionNames(banner))")
            return false
        }
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success else { return false }
        try? await Task.sleep(for: .milliseconds(60))
        // Its Send button, else the field's own confirm (Return).
        if let send = button(in: banner, titled: ["send", "reply"]),
           AXUIElementPerformAction(send, kAXPressAction as CFString) == .success { return true }
        return AXUIElementPerformAction(field, kAXConfirmAction as CFString) == .success
    }

    private static func textField(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        let role: String? = AXReader.value(element, kAXRoleAttribute)
        if role == kAXTextFieldRole || role == kAXTextAreaRole { return element }
        for child: AXUIElement in AXReader.value(element, kAXChildrenAttribute) ?? [] {
            if let found = textField(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func button(in element: AXUIElement, titled names: [String], depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        let role: String? = AXReader.value(element, kAXRoleAttribute)
        if role == kAXButtonRole {
            let title = ((AXReader.value(element, kAXTitleAttribute) as String?) ?? (AXReader.value(element, kAXDescriptionAttribute) as String?) ?? "").lowercased()
            if names.contains(title) { return element }
        }
        for child: AXUIElement in AXReader.value(element, kAXChildrenAttribute) ?? [] {
            if let found = button(in: child, titled: names, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Messages, by the name the notification shows (a contact or a group).
    private static func replyInMessages(to name: String, text: String) -> Bool {
        let quote = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = """
        tell application "Messages"
            set theText to "\(quote(text))"
            set matches to (every chat whose name is "\(quote(name))")
            if (count of matches) > 0 then
                send theText to item 1 of matches
                return "ok"
            end if
            repeat with c in chats
                try
                    repeat with p in participants of c
                        if full name of p is "\(quote(name))" or name of p is "\(quote(name))" then
                            send theText to c
                            return "ok"
                        end if
                    end repeat
                end try
            end repeat
            return "none"
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { DebugHooks.log("NotificationMirror: Messages script failed: \(error)") }
        return result?.stringValue == "ok"
    }

    // MARK: - Debug

    /// A made-up message, as if it had come in (its reply goes nowhere: there's no banner).
    func debugFake(app: String = "Messages", sender: String = "Sam", text: String = "Are you around later? Want to grab dinner") {
        show(Item(id: UUID().uuidString, app: app, bundleID: Self.bundleID(forApp: app), title: sender, subtitle: "", body: text,
                  date: Date(), canReply: true))
    }

    /// Logs every banner up now with its actions and texts (for finding a new app's reply box).
    func debugDump() {
        guard observedPID != 0 else { DebugHooks.log("NOTIFY not watching"); return }
        let app = AXUIElementCreateApplication(observedPID)
        for window: AXUIElement in AXReader.value(app, kAXWindowsAttribute) ?? [] {
            for banner in Self.banners(in: window) {
                DebugHooks.log("NOTIFY banner \(AXReader.value(banner, kAXDescriptionAttribute) as String? ?? "") actions=\(Self.actionNames(banner))")
                Self.dumpTree(banner, depth: 1)
            }
        }
    }

    private static func dumpTree(_ e: AXUIElement, depth: Int) {
        guard depth < 8 else { return }
        let role: String = AXReader.value(e, kAXRoleAttribute) ?? "?"
        let id: String = AXReader.value(e, kAXIdentifierAttribute) ?? ""
        let title: String = AXReader.value(e, kAXTitleAttribute) ?? ""
        let desc: String = AXReader.value(e, kAXDescriptionAttribute) ?? ""
        DebugHooks.log("NOTIFY " + String(repeating: "  ", count: depth) + "\(role) id=\(id) t=\(title) d=\(desc.prefix(60)) acts=\(actionNames(e))")
        for child: AXUIElement in AXReader.value(e, kAXChildrenAttribute) ?? [] { dumpTree(child, depth: depth + 1) }
    }
}
