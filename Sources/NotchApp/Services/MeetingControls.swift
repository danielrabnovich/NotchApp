import AppKit
import ApplicationServices

/// The call app's own buttons from the notch: camera, raise hand, leave. Each is the app's own
/// keyboard shortcut, sent to it for a moment and then back to the app you were in, so you never
/// leave what you're doing. The microphone stays the Mac's own mute (it works in every app).
@MainActor
enum MeetingControls {
    enum Action: CaseIterable {
        case camera, hand, leave

        var title: String {
            switch self {
            case .camera: "Camera On/Off"
            case .hand: "Raise Hand"
            case .leave: "Leave Call"
            }
        }

        var symbol: String {
            switch self {
            case .camera: "video.fill"
            case .hand: "hand.raised.fill"
            case .leave: "phone.down.fill"
            }
        }
    }

    private struct Keys {
        let key: CGKeyCode
        let flags: CGEventFlags
    }

    // Virtual key codes (kVK_ANSI_…).
    private static let e: CGKeyCode = 14, h: CGKeyCode = 4, k: CGKeyCode = 40, o: CGKeyCode = 31
    private static let v: CGKeyCode = 9, w: CGKeyCode = 13, y: CGKeyCode = 16

    /// Each app's shortcuts, from its own keyboard shortcut list.
    private static func keys(_ action: Action, app: String, isMeet: Bool) -> Keys? {
        switch (app, action) {
        case ("us.zoom.xos", .camera): Keys(key: v, flags: [.maskCommand, .maskShift])
        case ("us.zoom.xos", .hand): Keys(key: y, flags: .maskAlternate)
        case ("us.zoom.xos", .leave): Keys(key: w, flags: .maskCommand) // Zoom asks to confirm
        case ("com.microsoft.teams2", .camera), ("com.microsoft.teams", .camera): Keys(key: o, flags: [.maskCommand, .maskShift])
        case ("com.microsoft.teams2", .hand), ("com.microsoft.teams", .hand): Keys(key: k, flags: [.maskCommand, .maskShift])
        case ("com.microsoft.teams2", .leave), ("com.microsoft.teams", .leave): Keys(key: h, flags: [.maskCommand, .maskShift])
        case ("com.cisco.webexmeetingsapp", .camera), ("com.webex.meetingmanager", .camera): Keys(key: v, flags: [.maskCommand, .maskShift])
        // Google Meet in a browser, only while its tab is the one showing.
        case (_, .camera) where isMeet: Keys(key: e, flags: .maskCommand)
        case (_, .hand) where isMeet: Keys(key: h, flags: [.maskCommand, .maskControl])
        default: nil
        }
    }

    /// What the call's app can do from here.
    static func available() -> [Action] {
        guard let id = MeetingMonitor.shared.call?.bundleID else { return [] }
        // A browser could be on Meet in another tab: offer what Meet can do, and say so if it isn't showing.
        let browser = AppContext.kind(of: id) == .browser
        return Action.allCases.filter { keys($0, app: id, isMeet: browser) != nil }
    }

    static func perform(_ action: Action) {
        guard let call = MeetingMonitor.shared.call, let id = call.bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        guard AXIsProcessTrusted() else {
            ActivityCenter.shared.show(.notice(title: "Needs Accessibility", detail: "To press \(call.app)'s buttons for you", icon: "lock.fill", tone: .warning), for: 3)
            return
        }
        Haptics.tap()
        // The app's own menu command, pressed in place: nothing comes forward. Browsers' menus
        // are the browser's, not the call's, so Meet always goes by its shortcuts.
        if AppContext.kind(of: id) != .browser, pressMenuItem(for: action, in: app) {
            DebugHooks.log("MeetingControls: \(action) via \(call.app)'s menu")
            return
        }
        let meet = AppContext.kind(of: id) == .browser && isMeetShowing(in: id)
        guard let keys = keys(action, app: id, isMeet: meet) else {
            let detail = AppContext.kind(of: id) == .browser ? "Bring the Meet tab to the front first" : action.title
            ActivityCenter.shared.show(.notice(title: "\(call.app) can't do that from here", detail: detail, icon: action.symbol, tone: .warning), for: 2.5)
            return
        }
        let previous = FrontmostTracker.shared.userApp
        Task { @MainActor in
            // Wait until it's really in front: keys sent a moment too early go to the app you
            // were in, which is what made these miss now and then.
            guard await bringForward(app) else {
                ActivityCenter.shared.show(.notice(title: "Couldn't reach \(call.app)", detail: action.title, icon: action.symbol, tone: .warning), for: 2.5)
                return
            }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: keys.key, keyDown: down)
                event?.flags = keys.flags
                event?.post(tap: .cghidEventTap)
            }
            DebugHooks.log("MeetingControls: \(action) via shortcut in \(call.app)")
            // Back where you were, unless it's leaving (Zoom asks to confirm in its own window).
            guard action != .leave, let previous, previous.processIdentifier != app.processIdentifier else { return }
            try? await Task.sleep(for: .milliseconds(250))
            _ = await bringForward(previous)
        }
    }

    /// Activates an app and waits (up to a second) until it's frontmost. Opening it through
    /// Launch Services works from the background, where `activate()` is often turned down.
    private static func bringForward(_ app: NSRunningApplication) async -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            app.activate()
        }
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                try? await Task.sleep(for: .milliseconds(60)) // its key window settles
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Menu commands that do each thing, as call apps name them.
    private static func menuTitles(_ action: Action) -> [String] {
        switch action {
        case .camera: ["start video", "stop video", "turn camera on", "turn camera off", "turn on camera", "turn off camera",
                       "start my video", "stop my video"]
        case .hand: ["raise hand", "lower hand"]
        case .leave: ["leave meeting", "end meeting", "leave call", "hang up", "leave"]
        }
    }

    /// Finds the command in the app's menu bar (two levels down) and presses it.
    private static func pressMenuItem(for action: Action, in app: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let bar: AXUIElement = AXReader.value(element, kAXMenuBarAttribute) else { return false }
        let wanted = menuTitles(action)
        func children(_ e: AXUIElement) -> [AXUIElement] { AXReader.value(e, kAXChildrenAttribute) ?? [] }
        for top in children(bar).dropFirst() { // not the app's own menu
            for menu in children(top) {
                for item in children(menu) {
                    guard let title: String = AXReader.value(item, kAXTitleAttribute) else { continue }
                    let t = title.lowercased().trimmingCharacters(in: .whitespaces)
                    guard wanted.contains(where: { t == $0 || t.hasPrefix($0 + " ") || t.hasPrefix($0 + "…") }) else { continue }
                    let enabled: Bool = AXReader.value(item, kAXEnabledAttribute) ?? true
                    guard enabled else { continue }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    /// Brings the call's window forward.
    static func showCall() {
        guard let id = MeetingMonitor.shared.call?.bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        app.activate()
    }

    /// A browser's front window is on Google Meet (its title is "Meet – …" or names Google Meet).
    private static func isMeetShowing(in bundleID: String) -> Bool {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let window: AXUIElement = AXReader.value(element, kAXFocusedWindowAttribute) ?? AXReader.value(element, kAXMainWindowAttribute),
              let title: String = AXReader.value(window, kAXTitleAttribute) else { return false }
        return title.hasPrefix("Meet ") || title.contains("Google Meet") || title.contains("meet.google.com")
    }
}
