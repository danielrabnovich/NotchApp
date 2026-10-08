import AppKit
import SwiftUI

/// Something the search bar can do directly: add tasks, jot a note, start a timer, flip a control.
struct Command: Identifiable, Equatable {
    enum Action: Equatable {
        /// Task titles, each possibly with a due phrase ("call mom tomorrow 3pm").
        case addTasks([String])
        case completeTask(UUID)
        case appendNote(String)
        case startTimer(minutes: Int)
        case startPomodoro
        case startStopwatch
        case pauseTimer, resumeTimer, stopTimer
        case keepAwake(minutes: Int?)
        case stopKeepAwake
        case toggleDarkMode, toggleWiFi, toggleMic, lockScreen, screenshot, pickColor
        case setVolume(Float), setBrightness(Float)
        /// A normal quit, so apps still ask to save unsaved work.
        case quitApp(pid_t)
        case show(NotchTab, pane: String? = nil)
        case settings
        /// Fills the bar with a command's prefix (from the "/" list).
        case template(String)
        case createEvent(EventDraft)
        case moveEvent(id: String, title: String, start: Date, end: Date?)
        case deleteEvent(id: String, title: String)
        case media(MediaAction)
        case openApp(URL)
        /// A System Settings pane or other URL.
        case openURL(URL)
        case speedTest
        case copyText
        case flushDNS
        case toggleHiddenFiles, toggleDesktopIcons, toggleNightShift
        case stopPort(port: Int, pid: pid_t, name: String)
        case uninstall(URL)
        case copyClip(UUID)
        case emptyTrash
        case downloadMedia(URL, VideoDownloader.Format, height: Int?)
        case transformClipboard(TextTransform)
    }

    enum MediaAction: String, Equatable { case toggle, play, pause, next, previous }

    /// Safe, easily undone actions run straight away; changing or removing existing things
    /// (moving or deleting an event, quitting an app) is shown for a quick review first.
    var runsWithoutReview: Bool {
        switch action {
        case .moveEvent, .deleteEvent, .quitApp, .stopPort, .emptyTrash: false
        default: true
        }
    }

    let id = UUID()
    let action: Action
    let title: String
    var subtitle: String?
    let icon: String
    /// The verb beside ↩ on the highlighted row.
    var verb = "Run"

    static func == (a: Command, b: Command) -> Bool { a.action == b.action && a.title == b.title && a.subtitle == b.subtitle }
}

/// Recognises commands in what's typed. Deliberate prefixes only ("task …", "note …", "timer 10m"),
/// so ordinary searches never turn into actions by surprise.
@MainActor
enum CommandParser {
    static func parse(_ raw: String) -> [Command] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = q.lowercased()
        guard !q.isEmpty else { return [] }
        if lower == "/" || lower == "?" || lower == "help" || lower == "commands" { return templates }
        if lower.hasPrefix("/") {
            let rest = String(lower.dropFirst())
            let parsed = parse(String(q.dropFirst()))
            if !parsed.isEmpty { return parsed }
            return templates.filter { $0.title.lowercased().contains(rest) || ($0.subtitle ?? "").lowercased().contains(rest) }
        }

        if let c = tasks(q, lower) ?? note(q, lower) ?? complete(q, lower) ?? quit(lower) ?? event(q, lower) { return c }
        if let c = port(lower) ?? uninstall(q, lower) ?? clip(q, lower) ?? media(q, lower) { return c }
        if let c = vpn(lower) { return c }
        if let c = utility(lower) ?? transform(lower) { return [c] }
        if let c = media(lower) { return [c] }
        if let c = timer(lower) ?? awake(lower) ?? control(lower) { return [c] }
        if let c = navigation(lower) { return [c] }
        return []
    }

    // MARK: - Tasks and notes

    private static let taskPrefixes = ["add task ", "new task ", "task ", "todo ", "to-do ", "to do ", "remind me to ", "remind me "]
    private static let listPrefixes = ["tasks:", "todos:", "todo:", "to-do:", "task:", "list:", "checklist:"]

    private static func tasks(_ q: String, _ lower: String) -> [Command]? {
        // "tasks: milk, eggs; call mom" → one task per item.
        if let prefix = listPrefixes.first(where: lower.hasPrefix) {
            let items = q.dropFirst(prefix.count)
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { return [template(for: "tasks: ")] }
            return [addTasks(items)]
        }
        guard let prefix = taskPrefixes.first(where: lower.hasPrefix) else { return nil }
        let title = q.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        // "task milk, eggs, bread" reads as a list too.
        let items = title.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return [addTasks(items.count > 1 ? items : [title])]
    }

    static func addTasks(_ items: [String]) -> Command {
        if items.count == 1 {
            let (title, due) = DueDateParser.extract(from: items[0])
            return Command(action: .addTasks(items), title: "Add task “\(title)”",
                           subtitle: due.map { "Due " + dueText($0) } ?? "To today's tasks", icon: "checklist", verb: "Add")
        }
        return Command(action: .addTasks(items), title: "Add \(items.count) tasks",
                       subtitle: items.map { DueDateParser.extract(from: $0).title }.joined(separator: " · "), icon: "checklist", verb: "Add")
    }

    static func dueText(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "today \(time)" }
        if cal.isDateInTomorrow(date) { return "tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " " + time
    }

    private static let notePrefixes = ["note ", "note:", "jot ", "jot:", "jot down ", "write down ", "remember "]

    private static func note(_ q: String, _ lower: String) -> [Command]? {
        guard let prefix = notePrefixes.sorted(by: { $0.count > $1.count }).first(where: lower.hasPrefix) else { return nil }
        let text = q.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return [Command(action: .appendNote(text), title: "Jot down “\(text)”", subtitle: "Adds a line to Notes", icon: "note.text", verb: "Jot")]
    }

    /// "done call mom" ticks off matching open tasks.
    private static func complete(_ q: String, _ lower: String) -> [Command]? {
        guard let prefix = ["done ", "complete ", "finish ", "check off ", "tick off "].first(where: lower.hasPrefix) else { return nil }
        let needle = lower.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        let matches = TaskStore.shared.open.filter { $0.title.lowercased().contains(needle) }.prefix(3)
        guard !matches.isEmpty else {
            return [Command(action: .show(.tasks, pane: TasksPane.tasks.rawValue), title: "No open task matches “\(needle)”",
                            subtitle: "Show Tasks", icon: "checklist", verb: "Show")]
        }
        return matches.map { Command(action: .completeTask($0.id), title: "Complete “\($0.title)”",
                                     subtitle: $0.due.map { "Due " + dueText($0) }, icon: "checkmark.circle", verb: "Done") }
    }

    /// "quit spot" → Quit Spotify, matching running apps by name.
    private static func quit(_ lower: String) -> [Command]? {
        guard let prefix = ["quit ", "close app ", "kill "].first(where: lower.hasPrefix) else { return nil }
        let needle = lower.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
            .compactMap { app in app.localizedName.map { (app, $0) } }
            .filter { $0.1.lowercased().contains(needle) }
            // Names that start with what was typed first, then shorter names.
            .sorted { ($0.1.lowercased().hasPrefix(needle) ? 0 : 1, $0.1.count) < ($1.1.lowercased().hasPrefix(needle) ? 0 : 1, $1.1.count) }
            .prefix(3)
        guard !apps.isEmpty else {
            return [Command(action: .template("quit "), title: "No running app matches “\(needle)”", icon: "xmark.app", verb: "Edit")]
        }
        return apps.map { app, name in
            Command(action: .quitApp(app.processIdentifier), title: "Quit \(name)",
                    subtitle: app.isActive ? "Frontmost app" : "Running", icon: "xmark.app", verb: "Quit")
        }
    }

    // MARK: - Utilities

    /// "port 3000", "what's on port 8080", "ports".
    private static func port(_ lower: String) -> [Command]? {
        if ["ports", "open ports", "listening ports", "port list", "show ports"].contains(lower) {
            return [Command(action: .show(.controls, pane: "ports"), title: "Show listening ports", icon: "point.3.connected.trianglepath.dotted", verb: "Show")]
        }
        guard let prefix = ["port ", "what's on port ", "whats on port ", "what is on port ", "kill port ", "free port ", "lsof "]
            .first(where: lower.hasPrefix) else { return nil }
        guard let port = Int(lower.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: " :"))),
              (1...65535).contains(port) else { return nil }
        // lsof takes a moment, so the matching listeners are filled in by PortLookup as you type.
        let found = PortLookup.shared.listeners(for: port)
        guard let found else {
            return [Command(action: .template(prefix + "\(port)"), title: "Checking port \(port)…", icon: "point.3.connected.trianglepath.dotted", verb: "Wait")]
        }
        guard !found.isEmpty else {
            return [Command(action: .template(prefix), title: "Nothing is listening on port \(port)", subtitle: "It's free to use",
                            icon: "checkmark.circle", verb: "Edit")]
        }
        return found.map { l in
            l.isSystem
                ? Command(action: .template(prefix + String(port)), title: "\(l.displayName) is using port \(port)",
                          subtitle: "Part of macOS · PID " + String(l.pid), icon: "apple.logo", verb: "OK")
                : Command(action: .stopPort(port: port, pid: l.pid, name: l.displayName), title: "Stop \(l.displayName) on port \(port)",
                    subtitle: "PID " + String(l.pid) + " · \(l.isLocalOnly ? "this Mac only" : "all interfaces")", icon: "network.slash", verb: "Stop")
        }
    }

    /// A pasted link (or "download …", "audio …") → save it with yt-dlp.
    private static func media(_ q: String, _ lower: String) -> [Command]? {
        guard VideoDownloader.isAvailable else { return nil }
        let prefixes: [(String, VideoDownloader.Format?)] = [("download ", nil), ("yt ", nil), ("ytdl ", nil), ("yt-dlp ", nil),
                                                            ("video ", .video), ("audio ", .audio), ("mp3 ", .audio), ("m4a ", .audio)]
        let match = prefixes.first { lower.hasPrefix($0.0) }
        let rest = match.map { String(q.dropFirst($0.0.count)) } ?? q
        guard let url = VideoDownloader.webURL(rest) else { return nil }
        let host = url.host()?.replacingOccurrences(of: "www.", with: "") ?? "the web"
        let downloader = VideoDownloader.shared
        let info = downloader.cachedInfo(for: url)
        if info == nil, !downloader.isProbing(url) {
            // Ask yt-dlp what's on offer; the list fills in with each resolution when it answers.
            Task { if await downloader.probe(url) != nil { SearchSuggestions.shared.refresh() } }
        }
        let preferred = AppSettings.shared.videoQuality
        let audio = Command(action: .downloadMedia(url, .audio, height: nil), title: "Download audio only",
                            subtitle: "M4A from \(host)" + (info?.audioSize.map { " · ~" + formatBytes($0) } ?? ""),
                            icon: "music.note", verb: "Download")
        if match?.1 == .audio { return [audio] }
        var videos: [Command]
        if let qualities = info?.qualities, !qualities.isEmpty {
            // The default quality first (or the best below it), then the others, highest first.
            let first = qualities.first { preferred == 0 || $0.height <= preferred } ?? qualities[0]
            let ordered = [first] + qualities.filter { $0 != first }
            videos = ordered.prefix(4).map { q in
                Command(action: .downloadMedia(url, .video, height: q.height), title: "Download video · \(q.label)",
                        subtitle: q.detail + " · from \(host)", icon: "arrow.down.circle", verb: "Download")
            }
        } else {
            videos = [Command(action: .downloadMedia(url, .video, height: preferred > 0 ? preferred : nil), title: "Download video",
                              subtitle: (downloader.isProbing(url) || info == nil ? "Checking qualities… · " : "") + "from \(host)",
                              icon: "arrow.down.circle", verb: "Download")]
        }
        return match?.1 == .video ? videos : videos + [audio]
    }

    /// "uninstall slack".
    private static func uninstall(_ q: String, _ lower: String) -> [Command]? {
        guard let prefix = ["uninstall ", "remove app ", "delete app "].first(where: lower.hasPrefix) else { return nil }
        let needle = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, AppSettings.shared.toolsEnabled else { return nil }
        let hits = AppIndex.shared.search(needle, limit: 3).filter { $0.score >= 60 && !$0.app.url.path.hasPrefix("/System/") }
        guard !hits.isEmpty else {
            return [Command(action: .template(prefix), title: "No app matches “\(needle)”", icon: "xmark.app", verb: "Edit")]
        }
        return hits.map { hit in
            Command(action: .uninstall(hit.app.url), title: "Uninstall \(hit.app.name)…", subtitle: "Shows what will go to the Trash first",
                    icon: "xmark.app", verb: "Review")
        }
    }

    /// "clip invoice", "paste address": matching clipboard history.
    private static func clip(_ q: String, _ lower: String) -> [Command]? {
        guard AppSettings.shared.clipboardHistory,
              let prefix = ["clip ", "clipboard ", "paste ", "copied "].first(where: lower.hasPrefix) ?? (["clip", "clipboard"].contains(lower) ? lower : nil)
        else { return nil }
        let needle = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        let hits = ClipboardHistory.shared.search(needle, limit: 6)
        guard !hits.isEmpty else {
            return [Command(action: .show(.shelf, pane: ShelfPane.clipboard.rawValue), title: "Nothing copied matches “\(needle)”",
                            subtitle: "Show clipboard history", icon: "doc.on.clipboard", verb: "Show")]
        }
        return hits.map { clip in
            Command(action: .copyClip(clip.id), title: String(clip.title.replacingOccurrences(of: "\n", with: " ").prefix(80)),
                    subtitle: "Copied " + clip.date.formatted(.relative(presentation: .named)), icon: clip.icon, verb: "Copy")
        }
    }

    /// "format json", "base64 decode", "uppercase": applied to the clipboard, with a preview.
    private static func transform(_ lower: String) -> Command? {
        guard let t = TextTransform.allCases.first(where: { $0.phrases.contains(lower) }) else { return nil }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return Command(action: .transformClipboard(t), title: t.title, subtitle: "Copy some text first", icon: "wand.and.rays", verb: "Run")
        }
        // Short: the row drops a detail that doesn't fit whole.
        let preview = t.apply(text).map { out -> String in
            let flat = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return "→ " + (flat.count > 34 ? String(flat.prefix(33)) + "…" : flat)
        }
            ?? "Clipboard isn't valid for that"
        return Command(action: .transformClipboard(t), title: "\(t.title) on clipboard", subtitle: preview, icon: "wand.and.rays", verb: "Apply")
    }

    private static func utility(_ lower: String) -> Command? {
        let tweaks = SystemTweaks.shared
        switch lower {
        case "speedtest", "speed test", "speed", "internet speed", "test speed", "test internet", "network speed":
            return Command(action: .speedTest, title: "Run a speed test", subtitle: "Download, upload and responsiveness · about 20 seconds",
                           icon: "speedometer", verb: "Run")
        case "ocr", "copy text", "grab text", "text from screen", "copy text from screen", "scan text":
            return Command(action: .copyText, title: "Copy text from the screen", subtitle: "Drag over the text you want",
                           icon: "text.viewfinder", verb: "Start")
        case "flush dns", "flushdns", "clear dns", "dns flush", "reset dns":
            return Command(action: .flushDNS, title: "Flush the DNS cache", subtitle: "Asks for your password", icon: "arrow.clockwise.circle", verb: "Flush")
        case "hidden files", "show hidden files", "hide hidden files", "dotfiles":
            return Command(action: .toggleHiddenFiles, title: tweaks.hiddenFilesShown ? "Hide hidden files" : "Show hidden files",
                           subtitle: "Restarts Finder", icon: "eye", verb: "Toggle")
        case "desktop icons", "hide desktop", "hide desktop icons", "show desktop icons", "clean desktop":
            return Command(action: .toggleDesktopIcons, title: tweaks.desktopIconsHidden ? "Show desktop icons" : "Hide desktop icons",
                           subtitle: "Restarts Finder", icon: "menubar.dock.rectangle", verb: "Toggle")
        case "night shift", "nightshift", "toggle night shift":
            return Command(action: .toggleNightShift, title: tweaks.nightShiftOn ? "Turn Night Shift off" : "Turn Night Shift on",
                           icon: "moon.circle.fill", verb: "Toggle")
        case "empty trash", "empty the trash":
            return Command(action: .emptyTrash, title: "Empty the Trash", subtitle: "Can't be undone", icon: "trash.fill", verb: "Empty")
        case "clean", "cleaner", "clean up", "cleanup", "free space", "free up space", "disk space", "storage":
            guard AppSettings.shared.toolsEnabled else { return nil }
            let free = Cleaner.shared.disk.map { "\(formatBytes($0.available)) free" } ?? "Caches, logs, old downloads…"
            return Command(action: .show(.tools, pane: ToolsPane.cleaner.rawValue), title: "Free up space", subtitle: free,
                           icon: "sparkles", verb: "Show")
        default: return nil
        }
    }

    // MARK: - VPN

    private static let vpnSettingsURL = URL(string: "x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension")!

    /// "vpn" → the VPN pane, its System Settings and the VPN apps; "vpn settings" → Settings and the apps.
    private static func vpn(_ lower: String) -> [Command]? {
        let word = lower.hasPrefix("show ") ? String(lower.dropFirst(5)) : lower.hasPrefix("go to ") ? String(lower.dropFirst(6)) : lower
        let config = ["vpn settings", "vpn config", "vpn configuration", "vpn configs", "vpn preferences", "vpn prefs",
                      "configure vpn", "vpn setup", "set up vpn", "vpn profiles", "my vpn config", "my vpn settings"]
        guard word == "vpn" || word == "vpns" || config.contains(word) else { return nil }
        let settings = Command(action: .openURL(vpnSettingsURL), title: "Open VPN settings",
                               subtitle: "System Settings · profiles, on demand, add a configuration", icon: "gearshape.fill", verb: "Open")
        var found: [Command] = []
        // Asking for the config means Settings, not the pane (it'd also keep the highlight off Settings).
        if AppSettings.shared.toolsEnabled, !config.contains(word) {
            let up = VPNMonitor.shared.connections.filter(\.isUp).map(\.name)
            found.append(Command(action: .show(.tools, pane: ToolsPane.vpn.rawValue), title: "Show VPN",
                                 subtitle: up.isEmpty ? "Not connected" : "Connected · " + up.joined(separator: ", "),
                                 icon: "lock.shield.fill", verb: "Show"))
        }
        found.append(settings)
        // The VPN apps themselves, for their own server and account settings.
        let apps = VPNMonitor.shared.connections.compactMap(\.appURL)
        var seen = Set<URL>()
        for app in apps where seen.insert(app).inserted {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            found.append(Command(action: .openApp(app), title: "Open \(name)", subtitle: "Servers, account and app settings",
                                 icon: "arrow.up.forward.app", verb: "Open"))
        }
        return found
    }

    // MARK: - Calendar and media

    private static let eventPrefixes = ["add event ", "new event ", "create event ", "event ", "add to calendar ", "calendar add "]

    /// "event lunch with sam friday 1pm" → a calendar event, without needing the model.
    private static func event(_ q: String, _ lower: String) -> [Command]? {
        guard let prefix = eventPrefixes.first(where: lower.hasPrefix) else { return nil }
        let rest = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        guard let draft = DueDateParser.event(from: rest) else {
            return [Command(action: .template(prefix), title: "Add a day and time", subtitle: "“event lunch with Sam friday 1pm”",
                            icon: "calendar.badge.plus", verb: "Edit")]
        }
        return [createEvent(draft)]
    }

    static func createEvent(_ draft: EventDraft) -> Command {
        Command(action: .createEvent(draft), title: "Add “\(draft.title)” to your calendar",
                subtitle: eventText(draft.start, draft.end, allDay: draft.allDay) + (draft.calendarName.map { " · \($0)" } ?? ""),
                icon: "calendar.badge.plus", verb: "Add")
    }

    /// "Fri, Oct 9 · 1:00 – 2:00 PM", "Today · 3:00 – 3:30 PM", "Sat, Oct 10 · All day".
    static func eventText(_ start: Date, _ end: Date, allDay: Bool) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(start) ? "Today" : cal.isDateInTomorrow(start) ? "Tomorrow"
            : start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if allDay { return "\(day) · All day" }
        let t = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(day) · \(start.formatted(t)) – \(end.formatted(t))"
    }

    private static func media(_ lower: String) -> Command? {
        switch lower {
        case "play", "play music", "resume music": return Command(action: .media(.play), title: "Play", icon: "play.fill", verb: "Play")
        case "pause", "pause music", "stop music": return Command(action: .media(.pause), title: "Pause music", icon: "pause.fill", verb: "Pause")
        case "next", "next song", "skip", "skip song", "next track": return Command(action: .media(.next), title: "Next song", icon: "forward.fill", verb: "Skip")
        case "previous", "previous song", "last song", "previous track", "back": return Command(action: .media(.previous), title: "Previous song", icon: "backward.fill", verb: "Back")
        default: return nil
        }
    }

    // MARK: - Timer, keep awake, controls

    private static func timer(_ lower: String) -> Command? {
        switch lower {
        case "pomodoro", "focus", "start focus", "focus session", "start pomodoro":
            let m = TimerStore.shared.focusMinutes
            return Command(action: .startPomodoro, title: "Start a Pomodoro", subtitle: "\(m) min focus", icon: "brain.head.profile", verb: "Start")
        case "stopwatch", "start stopwatch":
            return Command(action: .startStopwatch, title: "Start the stopwatch", icon: "stopwatch", verb: "Start")
        case "pause", "pause timer":
            return Command(action: .pauseTimer, title: "Pause the timer", icon: "pause.fill", verb: "Pause")
        case "resume", "resume timer":
            return Command(action: .resumeTimer, title: "Resume the timer", icon: "play.fill", verb: "Resume")
        case "stop timer", "cancel timer", "reset timer":
            return Command(action: .stopTimer, title: "Stop the timer", icon: "stop.fill", verb: "Stop")
        default: break
        }
        for prefix in ["timer ", "set timer ", "set a timer for ", "timer for ", "focus for ", "start timer "] where lower.hasPrefix(prefix) {
            guard let minutes = minutes(in: String(lower.dropFirst(prefix.count))), minutes > 0, minutes <= 600 else { return nil }
            return Command(action: .startTimer(minutes: minutes), title: "Start a \(durationText(minutes)) timer", icon: "timer", verb: "Start")
        }
        return nil
    }

    private static func awake(_ lower: String) -> Command? {
        if ["stop keep awake", "keep awake off", "let sleep", "allow sleep", "stop caffeinate"].contains(lower) {
            return Command(action: .stopKeepAwake, title: "Let your Mac sleep again", icon: "moon.zzz", verb: "Stop")
        }
        for prefix in ["keep awake", "caffeinate", "stay awake", "awake"] where lower.hasPrefix(prefix) {
            let rest = lower.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let m = rest.isEmpty ? nil : minutes(in: rest.replacingOccurrences(of: "for ", with: ""))
            if !rest.isEmpty && m == nil { return nil }
            return Command(action: .keepAwake(minutes: m), title: "Keep your Mac awake",
                           subtitle: m.map { "For \(durationText($0))" } ?? "Until you turn it off", icon: "cup.and.saucer.fill", verb: "Start")
        }
        return nil
    }

    private static func control(_ lower: String) -> Command? {
        let controls = ControlsService.shared
        switch lower {
        case "dark mode", "light mode", "toggle dark mode", "appearance":
            return Command(action: .toggleDarkMode, title: controls.darkMode ? "Switch to light mode" : "Switch to dark mode",
                           icon: "circle.lefthalf.filled", verb: "Switch")
        case "wifi", "wi-fi", "toggle wifi", "wifi on", "wifi off":
            return Command(action: .toggleWiFi, title: controls.wifiOn ? "Turn Wi-Fi off" : "Turn Wi-Fi on", icon: "wifi", verb: "Toggle")
        case "mute mic", "unmute mic", "mic", "microphone", "toggle mic":
            return Command(action: .toggleMic, title: controls.micMuted ? "Unmute the microphone" : "Mute the microphone",
                           icon: controls.micMuted ? "mic.fill" : "mic.slash.fill", verb: "Toggle")
        case "lock", "lock screen", "lock mac":
            return Command(action: .lockScreen, title: "Lock screen", icon: "lock.fill", verb: "Lock")
        case "screenshot", "take screenshot", "screen shot":
            return Command(action: .screenshot, title: "Take a screenshot", icon: "camera.viewfinder", verb: "Capture")
        case "color picker", "colour picker", "pick color", "pick colour", "eyedropper":
            return Command(action: .pickColor, title: "Pick a colour from the screen", icon: "eyedropper", verb: "Pick")
        case "mute", "mute volume":
            return Command(action: .setVolume(0), title: "Mute sound", icon: "speaker.slash.fill", verb: "Mute")
        default: break
        }
        for (prefix, isVolume) in [("volume ", true), ("vol ", true), ("brightness ", false)] where lower.hasPrefix(prefix) {
            let digits = lower.dropFirst(prefix.count).filter(\.isNumber)
            guard let n = Int(digits), (0...100).contains(n) else { return nil }
            return isVolume
                ? Command(action: .setVolume(Float(n) / 100), title: "Set volume to \(n)%", icon: "speaker.wave.2.fill", verb: "Set")
                : Command(action: .setBrightness(Float(n) / 100), title: "Set brightness to \(n)%", icon: "sun.max.fill", verb: "Set")
        }
        return nil
    }

    private static func navigation(_ lower: String) -> Command? {
        let word = lower.hasPrefix("show ") ? String(lower.dropFirst(5)) : lower.hasPrefix("go to ") ? String(lower.dropFirst(6)) : lower
        let destinations: [(names: [String], title: String, action: Command.Action, icon: String)] = [
            (["tasks", "todo", "todos"], "Tasks", .show(.tasks, pane: TasksPane.tasks.rawValue), "checklist"),
            (["notes", "scratchpad"], "Notes", .show(.tasks, pane: TasksPane.notes.rawValue), "note.text"),
            (["shelf"], "Shelf", .show(.shelf, pane: ShelfPane.shelf.rawValue), "tray.full.fill"),
            (["downloads"], "Downloads", .show(.shelf, pane: ShelfPane.downloads.rawValue), "arrow.down.circle"),
            (["timer"], "Timer", .show(.timer), "timer"),
            (["mixer", "audio"], "Mixer", .show(.mixer), "slider.vertical.3"),
            (["controls"], "Controls", .show(.controls), "switch.2"),
            (["stats", "system", "activity"], "Stats", .show(.stats), "gauge.with.dots.needle.50percent"),
            (["tools", "network", "wifi info", "ip", "my ip", "ip address"], "Network", .show(.tools, pane: ToolsPane.network.rawValue), "network"),
            (["agents", "claude", "claude code", "codex", "opencode", "zcode", "tokens", "usage"], "Agents", .show(.agents), "sparkles.rectangle.stack.fill"),
            (["devices", "bluetooth", "airpods", "batteries"], "Devices", .show(.tools, pane: ToolsPane.devices.rawValue), "airpods"),
            (["clipboard", "clipboard history", "clips"], "Clipboard", .show(.shelf, pane: ShelfPane.clipboard.rawValue), "doc.on.clipboard"),
            (["home", "music", "calendar"], "Home", .show(.home), "house.fill"),
            (["settings", "preferences"], "Settings", .settings, "gearshape.fill"),
        ]
        guard let d = destinations.first(where: { $0.names.contains(word) }) else { return nil }
        return Command(action: d.action, title: "Show \(d.title)", icon: d.icon, verb: "Show")
    }

    // MARK: - "/" list

    private static func template(for prefix: String) -> Command {
        templates.first { if case .template(prefix) = $0.action { true } else { false } }!
    }

    static let templates: [Command] = [
        Command(action: .template("task "), title: "task …", subtitle: "“task call mom tomorrow 3pm” · or “tasks: milk, eggs” for several",
                icon: "checklist", verb: "Use"),
        Command(action: .template("note "), title: "note …", subtitle: "Jot a line into Notes", icon: "note.text", verb: "Use"),
        Command(action: .template("done "), title: "done …", subtitle: "Tick off a task by name", icon: "checkmark.circle", verb: "Use"),
        Command(action: .template("event "), title: "event …", subtitle: "“event lunch with Sam friday 1pm for 90 min”",
                icon: "calendar.badge.plus", verb: "Use"),
        Command(action: .template("timer "), title: "timer 10m", subtitle: "Countdown · or “pomodoro”, “stopwatch”", icon: "timer", verb: "Use"),
        Command(action: .template("quit "), title: "quit …", subtitle: "Quit a running app by name", icon: "xmark.app", verb: "Use"),
        Command(action: .template("port "), title: "port 3000", subtitle: "See what's listening on a port, and stop it · or “ports”",
                icon: "point.3.connected.trianglepath.dotted", verb: "Use"),
        Command(action: .template("speedtest"), title: "speedtest", subtitle: "Internet speed · also: vpn, ocr, flush dns, hidden files, night shift",
                icon: "speedometer", verb: "Use"),
        Command(action: .template("uninstall "), title: "uninstall …", subtitle: "Remove an app and the files it left behind",
                icon: "xmark.app", verb: "Use"),
        Command(action: .template("download "), title: "download <link>", subtitle: "Save a video with yt-dlp · or “audio <link>” · or just paste a link",
                icon: "arrow.down.circle", verb: "Use"),
        Command(action: .template("format json"), title: "format json", subtitle: "Also: base64, url decode, uppercase, plain text, sort lines… on the clipboard",
                icon: "wand.and.rays", verb: "Use"),
        Command(action: .template("clip "), title: "clip …", subtitle: "Find something you copied earlier", icon: "doc.on.clipboard", verb: "Use"),
        Command(action: .template("keep awake "), title: "keep awake 1h", subtitle: "Also: volume 40, brightness, dark mode, wifi, lock, screenshot",
                icon: "switch.2", verb: "Use"),
    ]

    // MARK: - Helpers

    /// "10", "10m", "10 min", "1h", "1.5 hours", "1h30" → minutes.
    nonisolated static func minutes(in text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard !t.isEmpty else { return nil }
        var total = 0.0
        var number = ""
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if c.isNumber || c == "." { number.append(c); i = t.index(after: i); continue }
            let rest = t[i...]
            let unit: Double
            let length: Int
            if let w = ["hours", "hour", "hrs", "hr", "h"].first(where: { rest.hasPrefix($0) }) { unit = 60; length = w.count }
            else if let w = ["minutes", "minute", "mins", "min", "m"].first(where: { rest.hasPrefix($0) }) { unit = 1; length = w.count }
            else if let w = ["seconds", "second", "secs", "sec", "s"].first(where: { rest.hasPrefix($0) }) { unit = 1.0 / 60; length = w.count }
            else { return nil }
            guard let n = Double(number) else { return nil }
            total += n * unit
            number = ""
            i = t.index(i, offsetBy: length)
        }
        if let n = Double(number) { total += n } // a bare number ("10") or the minutes in "1h30"
        let m = Int(total.rounded())
        return m > 0 ? m : nil
    }

    static func durationText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }
}

/// Runs commands and remembers the last outcome, shown briefly under the search bar.
@MainActor
final class CommandCenter: ObservableObject {
    static let shared = CommandCenter()

    struct Confirmation: Equatable {
        let id = UUID()
        let text: String
        let icon: String
        /// Where "Show" goes.
        var destination: Command.Action?
        var undo: Undo?
        var failed = false
    }

    enum Undo: Equatable {
        case deleteEvent(id: String)
        case restoreEvent(id: String, start: Date, end: Date)
        case recreateEvent(EventDraft)
    }

    @Published var confirmation: Confirmation?

    /// Runs commands in order and confirms what happened in one line.
    func run(_ commands: [Command]) {
        if UserDefaults.standard.bool(forKey: "debugDryRun") {
            DebugHooks.log("DRYRUN " + commands.map { "\($0.title) [\($0.subtitle ?? "")]" }.joined(separator: " + "))
            return
        }
        var added = 0, completed = 0, notes = 0
        var other: Confirmation?
        for command in commands {
            switch command.action {
            case .addTasks(let items):
                items.forEach { TaskStore.shared.add(title: $0) }
                added += items.count
            case .completeTask(let id):
                TaskStore.shared.setDone(id, true)
                completed += 1
            case .appendNote(let text):
                let store = ScratchpadStore.shared
                store.text += (store.text.isEmpty || store.text.hasSuffix("\n") ? "" : "\n") + text
                notes += 1
            default:
                other = perform(command)
            }
        }
        var parts: [String] = []
        if added > 0 { parts.append(added == 1 ? "Added a task" : "Added \(added) tasks") }
        if completed > 0 { parts.append(completed == 1 ? "Completed a task" : "Completed \(completed) tasks") }
        if notes > 0 { parts.append(notes == 1 ? "Jotted a note" : "Jotted \(notes) notes") }
        if !parts.isEmpty {
            let destination: Command.Action = added + completed > 0 ? .show(.tasks, pane: TasksPane.tasks.rawValue)
                                                                    : .show(.tasks, pane: TasksPane.notes.rawValue)
            confirm(Confirmation(text: parts.joined(separator: " · "), icon: "checkmark.circle.fill", destination: destination))
        } else if let other {
            confirm(other)
        }
    }

    private func confirm(_ c: Confirmation) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { confirmation = c }
        let linger: Double = c.undo != nil || c.failed ? 7 : 4
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { if self?.confirmation?.id == c.id { self?.confirmation = nil } }
        }
    }

    func undo(_ undo: Undo) {
        let calendar = CalendarManager.shared
        do {
            switch undo {
            case .deleteEvent(let id): _ = try calendar.delete(id: id)
            case .restoreEvent(let id, let start, let end): _ = try calendar.move(id: id, to: start, end: end)
            case .recreateEvent(let draft): _ = try calendar.create(draft)
            }
            confirm(Confirmation(text: "Undone", icon: "arrow.uturn.backward"))
        } catch {
            confirm(Confirmation(text: error.localizedDescription, icon: "exclamationmark.triangle.fill", failed: true))
        }
    }

    /// Single actions; returns a confirmation for the ones that don't explain themselves.
    private func perform(_ command: Command) -> Confirmation? {
        let calendar = CalendarManager.shared
        do {
            switch command.action {
            case .createEvent(let draft):
                let id = try calendar.create(draft)
                return Confirmation(text: "Added “\(draft.title)” · \(CommandParser.eventText(draft.start, draft.end, allDay: draft.allDay))",
                                    icon: "calendar.badge.checkmark", destination: .show(.home), undo: .deleteEvent(id: id))
            case .moveEvent(let id, let title, let start, let end):
                let old = try calendar.move(id: id, to: start, end: end)
                let newEnd = end ?? start.addingTimeInterval(old.end.timeIntervalSince(old.start))
                return Confirmation(text: "Moved “\(title)” to \(CommandParser.eventText(start, newEnd, allDay: false))",
                                    icon: "calendar", destination: .show(.home), undo: .restoreEvent(id: id, start: old.start, end: old.end))
            case .deleteEvent(let id, let title):
                let draft = try calendar.delete(id: id)
                return Confirmation(text: "Deleted “\(title)”", icon: "trash", undo: .recreateEvent(draft))
            default: break
            }
        } catch {
            return Confirmation(text: error.localizedDescription, icon: "exclamationmark.triangle.fill", failed: true)
        }
        if case .media(let m) = command.action {
            let media = MediaController.shared
            switch m {
            case .toggle: media.togglePlayPause()
            case .play: if !media.isPlaying { media.togglePlayPause() }
            case .pause: if media.isPlaying { media.togglePlayPause() }
            case .next: media.nextTrack()
            case .previous: media.previousTrack()
            }
            return nil
        }
        let timer = TimerStore.shared
        let controls = ControlsService.shared
        switch command.action {
        case .startTimer(let minutes):
            timer.reset(); timer.mode = .timer; timer.timerMinutes = minutes; timer.start()
            return Confirmation(text: "\(CommandParser.durationText(minutes)) timer started", icon: "timer", destination: .show(.timer))
        case .startPomodoro:
            timer.reset(); timer.mode = .pomodoro; timer.start()
            return Confirmation(text: "Pomodoro started", icon: "brain.head.profile", destination: .show(.timer))
        case .startStopwatch:
            timer.reset(); timer.mode = .stopwatch; timer.start()
            return Confirmation(text: "Stopwatch running", icon: "stopwatch", destination: .show(.timer))
        case .pauseTimer: timer.pause(); return Confirmation(text: "Timer paused", icon: "pause.fill", destination: .show(.timer))
        case .resumeTimer: timer.resume(); return Confirmation(text: "Timer resumed", icon: "play.fill", destination: .show(.timer))
        case .stopTimer: timer.reset(); return Confirmation(text: "Timer stopped", icon: "stop.fill")
        case .keepAwake(let minutes):
            KeepAwake.shared.start(minutes.map { .minutes($0) } ?? .indefinitely); return nil
        case .stopKeepAwake: KeepAwake.shared.stop(); return nil
        case .toggleDarkMode: controls.toggleDarkMode(); return nil
        case .toggleWiFi: controls.toggleWiFi(); return nil
        case .toggleMic: controls.toggleMic(); return nil
        case .lockScreen: controls.lockScreen(); return nil
        case .screenshot: NotchPresenter.shared.primary?.close(); controls.screenshot(); return nil
        case .pickColor: NotchPresenter.shared.primary?.close(); controls.pickColor(); return nil
        case .setVolume(let v): controls.setVolume(v); return nil
        case .setBrightness(let v): controls.setBrightness(v); return nil
        case .quitApp(let pid):
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            let name = app.localizedName ?? "App"
            app.terminate()
            return Confirmation(text: "Quit \(name)", icon: "xmark.app")
        case .show(let tab, let pane): show(tab, pane: pane); return nil
        case .settings: SettingsWindowController.shared.show(); return nil
        case .openApp(let url):
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            NotchPresenter.shared.primary?.close()
            return nil
        case .openURL(let url):
            NSWorkspace.shared.open(url)
            NotchPresenter.shared.primary?.close()
            return nil
        case .speedTest:
            SpeedTest.shared.start()
            return Confirmation(text: "Speed test running…", icon: "speedometer",
                                destination: AppSettings.shared.toolsEnabled ? .show(.tools, pane: ToolsPane.network.rawValue) : nil)
        case .copyText:
            NotchPresenter.shared.primary?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { SystemTweaks.shared.copyTextFromScreen() }
            return nil
        case .flushDNS: SystemTweaks.shared.flushDNS(); return nil
        case .toggleHiddenFiles: SystemTweaks.shared.toggleHiddenFiles(); return nil
        case .toggleDesktopIcons: SystemTweaks.shared.toggleDesktopIcons(); return nil
        case .toggleNightShift: SystemTweaks.shared.toggleNightShift(); return nil
        case .emptyTrash:
            Cleaner.emptyTrash { ok in
                if !ok { ActivityCenter.shared.show(.notice(title: "Couldn't empty the Trash", detail: "Allow NotchApp to control Finder", icon: "trash.slash", tone: .warning), for: 4) }
            }
            return Confirmation(text: "Emptied the Trash", icon: "trash.fill")
        case .stopPort(let port, let pid, let name):
            PortScanner.shared.stop(PortScanner.Listener(port: port, pid: pid, command: name, address: "*"))
            PortLookup.shared.invalidate()
            return Confirmation(text: "Stopped \(name) on port \(port)", icon: "network.slash")
        case .uninstall(let url):
            AppUninstaller.shared.inspect(url)
            show(.tools, pane: ToolsPane.cleaner.rawValue)
            return nil
        case .copyClip(let id):
            guard let clip = ClipboardHistory.shared.clips.first(where: { $0.id == id }) else { return nil }
            ClipboardHistory.shared.copy(clip)
            NotchPresenter.shared.primary?.close()
            return nil
        case .transformClipboard(let t):
            TextTransform.applyToClipboard(t)
            return nil
        case .downloadMedia(let url, let format, let height):
            VideoDownloader.shared.download(url, format: format, height: height)
            return Confirmation(text: "Downloading \(format == .audio ? "audio" : "video")…", icon: "arrow.down.circle",
                                destination: AppSettings.shared.shelfEnabled ? .show(.shelf, pane: ShelfPane.downloads.rawValue) : nil)
        case .addTasks, .completeTask, .appendNote, .template, .createEvent, .moveEvent, .deleteEvent, .media: return nil
        }
    }

    func show(_ tab: NotchTab, pane: String?) {
        if let pane {
            switch tab {
            case .tasks: UserDefaults.standard.set(pane, forKey: "tasks.pane")
            case .shelf: UserDefaults.standard.set(pane, forKey: "shelf.pane")
            case .tools: UserDefaults.standard.set(pane, forKey: "tools.pane")
            case .controls where pane == "ports":
                PortScanner.shared.refresh()
                PortScanner.shared.listOpen = true
            default: break
            }
        }
        guard let vm = NotchPresenter.shared.primary, vm.tabs.contains(tab) else { return }
        if vm.isOpen { vm.select(tab) } else { vm.open(tab: tab) }
    }
}

/// With a model, turns a plain request into a set of commands the user reviews before running:
/// "plan my move", "remind me to call mom tomorrow and buy eggs", "jot down the wifi password is …".
@MainActor
enum CommandPlanner {
    struct Plan: Equatable {
        var summary: String
        var commands: [Command]
    }

    static func plan(_ request: String) async throws -> Plan {
        let system = """
        You turn a request typed into a Mac's command bar into actions for a notch app with a to-do list, \
        a notes pad, a timer, keep-awake, music controls and the user's calendar.
        \(DateContext.prompt)
        Action types:
        {"type":"event","title":"short event name","start":"YYYY-MM-DDTHH:MM, or YYYY-MM-DD for an all-day event","end":"YYYY-MM-DDTHH:MM or null (1 hour)","location":"or null","calendar":"calendar name if the user named one, else null"}
        {"type":"move_event","event":"words identifying the existing event","on":"YYYY-MM-DD it's currently on, or null","new_start":"YYYY-MM-DDTHH:MM","new_end":"or null to keep its length"}
        {"type":"delete_event","event":"words identifying the existing event","on":"YYYY-MM-DD or null"}
        {"type":"media","command":"play|pause|next|previous"}
        {"type":"complete_task","task":"words from the task's title"}
        {"type":"stopwatch"}
        {"type":"timer_control","command":"pause|resume|stop"}
        {"type":"volume","percent":0-100}
        {"type":"brightness","percent":0-100}
        {"type":"toggle","setting":"dark_mode|wifi|mic","state":"on|off|toggle"}
        {"type":"lock_screen"}
        {"type":"screenshot"}
        {"type":"color_picker"}
        {"type":"open_app","name":"app name"}
        {"type":"quit_app","name":"app name"}
        {"type":"show","tab":"tasks|notes|shelf|downloads|clipboard|timer|mixer|controls|stats|tools|agents|network|devices|home|settings"}
        {"type":"task","title":"short imperative task","due":"when, in plain words like 'tomorrow 3pm' or 'friday', or null"}
        {"type":"note","text":"the text to jot down"}
        {"type":"timer","minutes":number}
        {"type":"pomodoro"}
        {"type":"keep_awake","minutes":number or null}
        Rules:
        - Lists, plans, checklists and "break down" requests: 3 to 8 concrete tasks, each under 8 words, in a sensible order.
        - If the user names items themselves, use their wording and add nothing.
        - "due" only when the user gave a time for that particular item ("call mom tomorrow"). An event date for a \
        whole plan ("party on saturday") is context, not a due date for every step: leave those null.
        - Things to remember or write down are notes, not tasks.
        - Meetings, appointments, classes, lunches, calls at a set time → "event" (a calendar entry), not a task. \
        "Remind me to …" without a fixed appointment is a task.
        - "Move/push/reschedule X to …" → move_event. "Cancel/delete/remove X" → delete_event.
        Reply with JSON only: {"summary":"one short line saying what you'll do","actions":[...]}
        """
        let obj = try await OllamaClient.chatJSON(system: system, user: request)
        var commands: [Command] = []
        for case let a as [String: Any] in obj["actions"] as? [Any] ?? [] {
            switch (a["type"] as? String ?? "").lowercased() {
            case "task":
                guard let title = (a["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
                let due = (a["due"] as? String).flatMap { $0.isEmpty || $0.lowercased() == "null" ? nil : $0 }
                commands.append(CommandParser.addTasks([due.map { "\(title) \($0)" } ?? title]))
            case "note":
                guard let text = (a["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                commands.append(Command(action: .appendNote(text), title: "Jot down “\(text)”", subtitle: "Notes", icon: "note.text", verb: "Jot"))
            case "timer":
                guard let m = (a["minutes"] as? NSNumber)?.intValue, m > 0, m <= 600 else { continue }
                commands.append(Command(action: .startTimer(minutes: m), title: "Start a \(CommandParser.durationText(m)) timer", icon: "timer", verb: "Start"))
            case "event":
                guard let title = (a["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                      let start = DateContext.parse(a["start"]) else { continue }
                let end = DateContext.parse(a["end"])?.date
                let draft: EventDraft
                if start.dateOnly {
                    let day = Calendar.current.startOfDay(for: start.date)
                    draft = EventDraft(title: title, start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day)!, allDay: true,
                                       location: a["location"] as? String, calendarName: a["calendar"] as? String)
                } else {
                    draft = EventDraft(title: title, start: start.date,
                                       end: end.flatMap { $0 > start.date ? $0 : nil } ?? start.date.addingTimeInterval(3600),
                                       location: (a["location"] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 },
                                       calendarName: (a["calendar"] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 })
                }
                commands.append(CommandParser.createEvent(draft))
            case "move_event":
                guard let what = a["event"] as? String, let newStart = DateContext.parse(a["new_start"]) else { continue }
                guard let event = CalendarManager.shared.findEvent(what, near: DateContext.parse(a["on"])?.date) else {
                    throw CalendarManager.ToolError.notFound(what)
                }
                let newEnd = DateContext.parse(a["new_end"])?.date
                let length = event.endDate.timeIntervalSince(event.startDate)
                let title = event.title ?? what
                commands.append(Command(action: .moveEvent(id: event.eventIdentifier, title: title, start: newStart.date, end: newEnd),
                                        title: "Move “\(title)”",
                                        subtitle: "\(CommandParser.eventText(event.startDate, event.endDate, allDay: event.isAllDay)) → \(CommandParser.eventText(newStart.date, newEnd ?? newStart.date.addingTimeInterval(length), allDay: false))",
                                        icon: "calendar", verb: "Move"))
            case "delete_event":
                guard let what = a["event"] as? String else { continue }
                guard let event = CalendarManager.shared.findEvent(what, near: DateContext.parse(a["on"])?.date) else {
                    throw CalendarManager.ToolError.notFound(what)
                }
                let title = event.title ?? what
                commands.append(Command(action: .deleteEvent(id: event.eventIdentifier, title: title), title: "Delete “\(title)”",
                                        subtitle: CommandParser.eventText(event.startDate, event.endDate, allDay: event.isAllDay),
                                        icon: "trash", verb: "Delete"))
            case "media":
                let map: [String: Command.MediaAction] = ["play": .play, "pause": .pause, "next": .next, "skip": .next, "previous": .previous]
                guard let m = map[(a["command"] as? String ?? "").lowercased()] else { continue }
                commands.append(Command(action: .media(m), title: m == .next ? "Next song" : m == .previous ? "Previous song" : m == .pause ? "Pause music" : "Play music",
                                        icon: m == .pause ? "pause.fill" : m == .next ? "forward.fill" : m == .previous ? "backward.fill" : "play.fill", verb: "Run"))
            case "complete_task":
                let needle = (a["task"] as? String ?? "").lowercased()
                guard !needle.isEmpty else { continue }
                let words = needle.split(separator: " ").map(String.init).filter { $0.count > 2 }
                if let task = TaskStore.shared.open.max(by: { x, y in
                    words.filter { x.title.lowercased().contains($0) }.count < words.filter { y.title.lowercased().contains($0) }.count
                }), words.contains(where: { task.title.lowercased().contains($0) }) {
                    commands.append(Command(action: .completeTask(task.id), title: "Complete “\(task.title)”", icon: "checkmark.circle", verb: "Done"))
                }
            case "stopwatch":
                commands.append(Command(action: .startStopwatch, title: "Start the stopwatch", icon: "stopwatch", verb: "Start"))
            case "timer_control":
                switch (a["command"] as? String ?? "").lowercased() {
                case "pause": commands.append(Command(action: .pauseTimer, title: "Pause the timer", icon: "pause.fill", verb: "Pause"))
                case "resume": commands.append(Command(action: .resumeTimer, title: "Resume the timer", icon: "play.fill", verb: "Resume"))
                case "stop": commands.append(Command(action: .stopTimer, title: "Stop the timer", icon: "stop.fill", verb: "Stop"))
                default: continue
                }
            case "volume", "brightness":
                guard let n = (a["percent"] as? NSNumber)?.intValue, (0...100).contains(n) else { continue }
                let isVolume = (a["type"] as? String) == "volume"
                commands.append(isVolume
                    ? Command(action: .setVolume(Float(n) / 100), title: "Set volume to \(n)%", icon: "speaker.wave.2.fill", verb: "Set")
                    : Command(action: .setBrightness(Float(n) / 100), title: "Set brightness to \(n)%", icon: "sun.max.fill", verb: "Set"))
            case "toggle":
                // "Turn on dark mode" when it's already on does nothing, rather than flipping it off.
                let state = (a["state"] as? String ?? "toggle").lowercased()
                let controls = ControlsService.shared
                func wanted(_ isOn: Bool) -> Bool { state == "on" ? !isOn : state == "off" ? isOn : true }
                switch (a["setting"] as? String ?? "").lowercased() {
                case "dark_mode" where wanted(controls.darkMode):
                    commands.append(Command(action: .toggleDarkMode, title: controls.darkMode ? "Switch to light mode" : "Switch to dark mode",
                                            icon: "circle.lefthalf.filled", verb: "Switch"))
                case "wifi" where wanted(controls.wifiOn):
                    commands.append(Command(action: .toggleWiFi, title: controls.wifiOn ? "Turn Wi-Fi off" : "Turn Wi-Fi on", icon: "wifi", verb: "Toggle"))
                case "mic" where wanted(!controls.micMuted):
                    commands.append(Command(action: .toggleMic, title: controls.micMuted ? "Unmute the microphone" : "Mute the microphone",
                                            icon: "mic.fill", verb: "Toggle"))
                default: continue
                }
            case "lock_screen":
                commands.append(Command(action: .lockScreen, title: "Lock screen", icon: "lock.fill", verb: "Lock"))
            case "screenshot":
                commands.append(Command(action: .screenshot, title: "Take a screenshot", icon: "camera.viewfinder", verb: "Capture"))
            case "color_picker":
                commands.append(Command(action: .pickColor, title: "Pick a colour from the screen", icon: "eyedropper", verb: "Pick"))
            case "open_app":
                guard let name = a["name"] as? String, let hit = AppIndex.shared.search(name, limit: 1).first else { continue }
                commands.append(Command(action: .openApp(hit.app.url), title: "Open \(hit.app.name)", icon: "app", verb: "Open"))
            case "quit_app":
                guard let name = a["name"] as? String else { continue }
                commands += CommandParser.parse("quit " + name).filter { if case .quitApp = $0.action { true } else { false } }.prefix(1)
            case "show":
                let tab = (a["tab"] as? String ?? "").lowercased()
                commands += CommandParser.parse("show " + tab).prefix(1)
            case "pomodoro":
                commands.append(Command(action: .startPomodoro, title: "Start a Pomodoro", icon: "brain.head.profile", verb: "Start"))
            case "keep_awake":
                let m = (a["minutes"] as? NSNumber)?.intValue
                commands.append(Command(action: .keepAwake(minutes: m), title: "Keep your Mac awake",
                                        subtitle: m.map { "For \(CommandParser.durationText($0))" }, icon: "cup.and.saucer.fill", verb: "Start"))
            default: continue
            }
        }
        let summary = (obj["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Here's the plan"
        DebugHooks.log("Planner: \(request) → \(commands.map(\.title))")
        return Plan(summary: summary, commands: commands)
    }

    /// Requests that sound like "do something" rather than "find something", for offering the AI row.
    static func looksLikeRequest(_ q: String) -> Bool {
        let lower = q.lowercased()
        guard lower.split(separator: " ").count >= 3 else { return false }
        let starts = ["plan ", "make ", "create ", "list ", "break down ", "help me ", "remind me ", "prepare ", "organize ",
                      "move ", "reschedule ", "push ", "cancel ", "delete ", "book ", "put ", "block ",
                      "organise ", "schedule ", "add ", "jot ", "write down ", "set up ", "i need to ", "i have to ", "todo ",
                      "to do ", "checklist ", "remember "]
        return starts.contains { lower.hasPrefix($0) } || lower.contains("to-do") || lower.contains("checklist")
            || lower.contains("task list") || lower.contains(" tasks for ")
    }
}
