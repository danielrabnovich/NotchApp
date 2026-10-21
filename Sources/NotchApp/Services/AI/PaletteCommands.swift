import AppKit
import CoreServices

/// A Settings switch the command bar can flip in place ("haptics", "turn off shadow").
struct SettingSwitch: Hashable {
    let title: String
    let pane: SettingsPane
    /// Other words people use for it.
    let words: [String]
    let key: ReferenceWritableKeyPath<AppSettings, Bool>

    @MainActor var isOn: Bool { AppSettings.shared[keyPath: key] }

    static func == (a: SettingSwitch, b: SettingSwitch) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }
}

/// Raycast-style extras for the command bar: Settings (flip a switch or open its page), translate,
/// define, web shortcuts and power commands.
@MainActor
enum PaletteCommands {
    // MARK: - Settings

    static let switches: [SettingSwitch] = [
        .init(title: "Haptic feedback", pane: .appearance, words: ["haptics", "vibration", "trackpad taps"], key: \.haptics),
        .init(title: "Shadow when open", pane: .appearance, words: ["shadow"], key: \.showShadow),
        .init(title: "Menu bar icon", pane: .general, words: ["status item", "menubar"], key: \.showMenuBarIcon),
        .init(title: "Fake notch on other displays", pane: .general, words: ["fake notch", "external display"], key: \.showFakeNotch),
        .init(title: "Focus search on hover", pane: .general, words: ["hover focus", "keyboard on hover"], key: \.focusSearchOnHover),
        .init(title: "Keyboard shortcuts", pane: .shortcuts, words: ["hotkeys", "shortcuts"], key: \.hotKeysEnabled),
        .init(title: "Volume HUD", pane: .hud, words: ["volume overlay", "hud"], key: \.volumeHUD),
        .init(title: "Brightness HUD", pane: .hud, words: ["brightness overlay"], key: \.brightnessHUD),
        .init(title: "Charging animation", pane: .battery, words: ["charging", "plug in"], key: \.chargingAnimation),
        .init(title: "Music", pane: .media, words: ["now playing", "media"], key: \.musicEnabled),
        .init(title: "Music visualizer", pane: .media, words: ["visualizer", "bars"], key: \.showVisualizer),
        .init(title: "Shelf", pane: .shelf, words: ["drop files"], key: \.shelfEnabled),
        .init(title: "Catch screenshots on the Shelf", pane: .shelf, words: ["screenshot catcher", "screenshots"], key: \.screenshotCatcher),
        .init(title: "Copy what lands on the Shelf", pane: .shelf, words: ["copy shelf"], key: \.copyShelfAdds),
        .init(title: "Random file names on the Shelf", pane: .shelf, words: ["random names", "rename", "anonymous files"], key: \.shelfRandomNames),
        .init(title: "Clean copied links", pane: .shelf, words: ["tracking", "utm", "clean links", "strip tracking"], key: \.cleanLinks),
        .init(title: "Clipboard history", pane: .shelf, words: ["clipboard", "copies"], key: \.clipboardHistory),
        .init(title: "Tasks", pane: .tasks, words: ["todo", "to-do"], key: \.tasksEnabled),
        .init(title: "Task count beside the notch", pane: .tasks, words: ["task badge", "badge"], key: \.showTaskCount),
        .init(title: "Timer", pane: .timer, words: ["pomodoro", "stopwatch"], key: \.timerEnabled),
        .init(title: "Timer sounds", pane: .timer, words: ["chime", "timer sound"], key: \.timerSounds),
        .init(title: "Sound mixer", pane: .media, words: ["mixer", "per-app volume"], key: \.mixerEnabled),
        .init(title: "Stats", pane: .stats, words: ["cpu", "system stats"], key: \.statsEnabled),
        .init(title: "Fahrenheit", pane: .stats, words: ["temperature unit", "celsius"], key: \.useFahrenheit),
        .init(title: "Tools", pane: .tools, words: ["network tools", "cleaner"], key: \.toolsEnabled),
        .init(title: "Agents", pane: .agents, words: ["claude code", "codex", "coding agents"], key: \.agentsEnabled),
        .init(title: "Agent alerts", pane: .agents, words: ["agent notifications"], key: \.agentAlerts),
        .init(title: "Keep awake while agents work", pane: .agents, words: ["agents keep awake"], key: \.agentsKeepAwake),
        .init(title: "Calendar", pane: .calendar, words: ["events"], key: \.calendarEnabled),
        .init(title: "Record calls", pane: .calendar, words: ["transcribe calls", "transcripts", "meeting notes", "call notes", "call recording"], key: \.transcribeCalls),
        .init(title: "Sound alerts", pane: .tools, words: ["doorbell", "sound recognition", "headphone alerts"], key: \.soundAlerts),
        .init(title: "Meeting alerts", pane: .calendar, words: ["meeting reminders"], key: \.meetingAlerts),
        .init(title: "Morning brief", pane: .assistant, words: ["brief", "daily summary"], key: \.morningBrief),
        .init(title: "Due-soon nudges", pane: .assistant, words: ["nudges", "reminders"], key: \.dueNudges),
        .init(title: "Questions about your screen", pane: .assistant, words: ["screen questions", "ask about screen"], key: \.screenQuestions),
        .init(title: "Search inside pictures", pane: .assistant, words: ["image search", "photo search", "image index"], key: \.imageIndexing),
        .init(title: "Recall what you've seen", pane: .assistant, words: ["recall", "screen memory", "screen history"], key: \.recall),
        .init(title: "Search the text in screenshots", pane: .assistant, words: ["screenshot search", "ocr"], key: \.screenshotSearch),
        .init(title: "Camera mirror", pane: .controls, words: ["mirror", "camera"], key: \.cameraMirrorEnabled),
        .init(title: "Reverse mouse scrolling", pane: .mouse, words: ["scroll direction", "natural scrolling"], key: \.reverseMouseScroll),
        .init(title: "Three-finger middle click", pane: .mouse, words: ["middle click"], key: \.threeFingerMiddleClick),
        .init(title: "Connection alerts", pane: .tools, words: ["offline alerts", "vpn alerts"], key: \.connectionAlerts),
        .init(title: "Dev server alerts", pane: .tools, words: ["localhost", "dev server"], key: \.devServerAlerts),
        .init(title: "Mic & camera alerts", pane: .tools, words: ["privacy alerts"], key: \.privacyAlerts),
        .init(title: "Update checks", pane: .updates, words: ["homebrew updates", "updates"], key: \.updateChecks),
    ]

    private static let settingPrefixes = ["settings ", "setting ", "toggle ", "turn on ", "turn off ", "enable ", "disable ", "switch on ", "switch off "]

    /// Switches and Settings pages matching what's typed. `explicit` when it started with
    /// "settings", "toggle", "turn on"…; otherwise only close matches, so searches stay searches.
    static func settings(_ raw: String) -> (commands: [Command], explicit: Bool) {
        // Padded, so a bare "settings" or "toggle" counts as the prefix too.
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces) + " "
        let prefix = settingPrefixes.first(where: lower.hasPrefix)
        let q = (prefix.map { String(lower.dropFirst($0.count)) } ?? lower).trimmingCharacters(in: .whitespaces)
        let want: Bool? = prefix.map { ["turn on ", "enable ", "switch on "].contains($0) ? true
                                       : ["turn off ", "disable ", "switch off "].contains($0) ? false : nil } ?? nil
        let explicit = prefix != nil
        guard q.count >= (explicit ? 2 : 4) else {
            return explicit ? (SettingsPane.allCases.prefix(6).map(openPane), true) : ([], false)
        }
        let found = switches.filter { s in
            let title = s.title.lowercased()
            return explicit ? title.contains(q) || s.words.contains { $0.contains(q) || q.contains($0) }
                            : title.hasPrefix(q) || s.words.contains { $0.hasPrefix(q) }
        }
        var out = found.prefix(3).map { toggle($0, to: want) }
        let panes = SettingsPane.allCases.filter { pane in
            explicit ? pane.matches(q) : pane.title.lowercased().hasPrefix(q)
        }
        out += panes.prefix(explicit ? 3 : 1).map(openPane)
        return (Array(out), explicit)
    }

    private static func toggle(_ s: SettingSwitch, to want: Bool?) -> Command {
        let next = want ?? !s.isOn
        return Command(action: .toggleSetting(s, next), title: "Turn \(s.title) \(next ? "on" : "off")",
                       subtitle: "Settings → \(s.pane.title) · now \(s.isOn ? "on" : "off")",
                       icon: next ? "switch.2" : "poweroff", verb: next ? "Turn On" : "Turn Off")
    }

    private static func openPane(_ pane: SettingsPane) -> Command {
        Command(action: .settingsPane(pane), title: "\(pane.title) Settings", subtitle: pane.summary,
                icon: pane.icon, verb: "Open")
    }

    // MARK: - Translate

    /// "translate hola to english", "translate to french" (the selection or clipboard), "tr …".
    static func translate(_ q: String, _ lower: String) -> Command? {
        guard let prefix = ["translate ", "tr "].first(where: lower.hasPrefix) else { return nil }
        var text = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        var target = "English"
        if let range = text.range(of: #"\s*(?:^|\s)(?:to|into|in)\s+([A-Za-zÀ-ÿ ]{2,24})$"#, options: [.regularExpression, .caseInsensitive]) {
            let words = text[range].split(separator: " ").drop { ["to", "into", "in"].contains($0.lowercased()) }
            target = words.joined(separator: " ").capitalized
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else if lower.hasPrefix(prefix + "to ") {
            target = String(text.dropFirst(3)).capitalized
            text = ""
        }
        if text.isEmpty {
            let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !clip.isEmpty else {
                return Command(action: .template("translate "), title: "Translate what?",
                               subtitle: "Type it after “translate”, or copy it first", icon: "character.bubble", verb: "Edit")
            }
            return Command(action: .translate(nil, to: target), title: "Translate the clipboard to \(target)",
                           subtitle: String(clip.prefix(80)), icon: "character.bubble", verb: "Translate")
        }
        return Command(action: .translate(text, to: target), title: "Translate to \(target)",
                       subtitle: String(text.prefix(80)), icon: "character.bubble", verb: "Translate")
    }

    // MARK: - Define

    /// "define serendipity": the Mac's own dictionary, offline.
    static func define(_ lower: String) -> Command? {
        guard let prefix = ["define ", "definition of ", "meaning of ", "dict "].first(where: lower.hasPrefix) else { return nil }
        let word = String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, let url = URL(string: "dict://" + (word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word)) else { return nil }
        let definition = DCSCopyTextDefinition(nil, word as CFString, CFRange(location: 0, length: (word as NSString).length))?
            .takeRetainedValue() as String?
        // "serendipity ser·en·dip·i·ty | ˌserənˈdipədē | noun the occurrence…": skip the headword and
        // pronunciation, keep the definition, short enough to fit the row.
        let summary = definition.map { text -> String in
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            // "headword | pronunciation | definition…": the definition starts after the second bar.
            let parts = flat.components(separatedBy: "|")
            var body = parts.count >= 3 ? parts[2...].joined(separator: "|") : flat
            if let origin = body.range(of: " ORIGIN") { body = String(body[..<origin.lowerBound]) }
            return body.trimmingCharacters(in: .whitespaces)
        }
        return Command(action: .openURL(url), title: "Define “\(word)”",
                       subtitle: summary.map { String($0.prefix(200)) } ?? "Not in the dictionary · open Dictionary",
                       icon: "character.book.closed", verb: "Open")
    }

    // MARK: - Web shortcuts

    private static let webShortcuts: [(prefixes: [String], name: String, url: String, icon: String)] = [
        (["google ", "g "], "Google", "https://www.google.com/search?q=", "magnifyingglass"),
        (["youtube ", "yt "], "YouTube", "https://www.youtube.com/results?search_query=", "play.rectangle.fill"),
        (["github ", "gh "], "GitHub", "https://github.com/search?q=", "chevron.left.forwardslash.chevron.right"),
        (["maps ", "map "], "Maps", "maps://?q=", "map.fill"),
        (["wiki ", "wikipedia "], "Wikipedia", "https://en.wikipedia.org/w/index.php?search=", "book.fill"),
        (["amazon "], "Amazon", "https://www.amazon.com/s?k=", "cart.fill"),
        (["reddit "], "Reddit", "https://www.reddit.com/search/?q=", "bubble.left.and.bubble.right.fill"),
    ]

    static func web(_ q: String, _ lower: String) -> Command? {
        for s in webShortcuts {
            guard let prefix = s.prefixes.first(where: lower.hasPrefix) else { continue }
            let term = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, let url = URL(string: s.url + (term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term))
            else { return nil }
            return Command(action: .openURL(url), title: "Search \(s.name) for “\(term)”", icon: s.icon, verb: "Open")
        }
        return nil
    }

    // MARK: - Power

    enum Power: String, Equatable {
        case sleep, displaySleep, restart, shutDown, logOut
    }

    static func power(_ lower: String) -> Command? {
        let all: [(names: [String], power: Power, title: String, icon: String)] = [
            (["sleep", "sleep mac", "go to sleep"], .sleep, "Sleep", "moon.fill"),
            (["sleep displays", "sleep display", "display sleep", "screen off", "turn off display"], .displaySleep, "Sleep Displays", "display"),
            (["restart", "reboot"], .restart, "Restart…", "arrow.clockwise"),
            (["shut down", "shutdown", "power off"], .shutDown, "Shut Down…", "power"),
            (["log out", "logout", "sign out"], .logOut, "Log Out…", "rectangle.portrait.and.arrow.right"),
        ]
        guard let p = all.first(where: { $0.names.contains(lower) }) else { return nil }
        let asks = [.restart, .shutDown, .logOut].contains(p.power)
        return Command(action: .power(p.power), title: p.title, subtitle: asks ? "macOS asks to confirm" : nil, icon: p.icon,
                       verb: p.title.replacingOccurrences(of: "…", with: ""))
    }

    /// Restart, shut down and log out go through loginwindow, which shows macOS's own confirmation.
    static func run(_ power: Power) {
        switch power {
        case .sleep: Task.detached { _ = Shell.runSync("/usr/bin/pmset", ["sleepnow"], timeout: 5) }
        case .displaySleep: Task.detached { _ = Shell.runSync("/usr/bin/pmset", ["displaysleepnow"], timeout: 5) }
        case .restart: loginwindow("rrst")
        case .shutDown: loginwindow("rsdn")
        case .logOut: loginwindow("logo")
        }
    }

    private static func loginwindow(_ code: String) {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"loginwindow\" to «event aevt\(code)»")?.executeAndReturnError(&error)
        if let error { DebugHooks.log("Power \(code) failed: \(error)") }
    }

    // MARK: - Windows

    /// "left half", "maximize", "window center", "next display"…
    static func window(_ lower: String) -> Command? {
        let q = lower.hasPrefix("window ") ? String(lower.dropFirst(7)) : lower
        guard q.count >= 3 else { return nil }
        guard let action = WindowManager.Action.allCases.first(where: {
            $0.title.lowercased() == q || $0.words.contains(q) || (lower.hasPrefix("window ") && $0.title.lowercased().hasPrefix(q))
        }) else { return nil }
        return Command(action: .window(action), title: "Window: \(action.title)", subtitle: "The window in front",
                       icon: action.icon, verb: "Move")
    }

    static let templates: [Command] = [
        Command(action: .template("settings "), title: "settings …", subtitle: "Flip a switch or open a page · “turn off haptics”, “settings glances”",
                icon: "gearshape.fill", verb: "Use"),
        Command(action: .template("translate "), title: "translate … to …", subtitle: "Any language · or “translate to french” for the clipboard",
                icon: "character.bubble", verb: "Use"),
        Command(action: .template("define "), title: "define …", subtitle: "The Mac's dictionary, offline", icon: "character.book.closed", verb: "Use"),
        Command(action: .template("google "), title: "google …", subtitle: "Also: youtube, github, maps, wiki, amazon, reddit",
                icon: "magnifyingglass", verb: "Use"),
        Command(action: .template("sleep"), title: "sleep", subtitle: "Also: sleep displays, restart, shut down, log out",
                icon: "moon.fill", verb: "Use"),
        Command(action: .template("ai "), title: "ai …", subtitle: "Your AI Commands on the selected text · fix grammar, summarize…",
                icon: "sparkles", verb: "Use"),
        Command(action: .template("menu "), title: "menu …", subtitle: "Run any menu command of the app in front", icon: "filemenu.and.selection", verb: "Use"),
        Command(action: .template("window "), title: "window …", subtitle: "left half, right half, maximize, center, thirds, next display, restore",
                icon: "rectangle.split.2x1", verb: "Use"),
    ]
}
