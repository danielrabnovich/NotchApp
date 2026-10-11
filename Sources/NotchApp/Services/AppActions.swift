import AppKit
import ApplicationServices
import NaturalLanguage

/// The app in front as the notch opens: what kind of app it is, the page or file it shows, and the
/// selected text. A light Accessibility read (no walk through the window's text); held in memory only.
struct AppContext: @unchecked Sendable {
    enum Kind { case browser, mail, chat, notes, writing, code, terminal, finder, other }

    let pid: pid_t
    let bundleID: String?
    let appName: String
    let bundlePath: String?
    let kind: Kind
    var windowTitle: String?
    /// The page, in a browser.
    var url: URL?
    /// The open document (or, in Finder, the folder).
    var filePath: String?
    var selection: String?
    /// The selection is in a text field you can type in, so an AI Command can replace it.
    var selectionEditable = false
    /// Files selected in Finder.
    var files: [URL] = []
    /// Finder's selection can't be read until NotchApp is allowed to ask Finder for it (asked on a click,
    /// never just by opening the notch).
    var needsFinderPermission = false

    static func kind(of bundleID: String?) -> Kind {
        guard let id = bundleID?.lowercased() else { return .other }
        let browsers = ["com.apple.safari", "com.apple.safaritechnologypreview", "com.google.chrome", "com.google.chrome.canary",
                        "company.thebrowser.browser", "company.thebrowser.dia", "com.brave.browser", "com.brave.browser.beta",
                        "com.microsoft.edgemac", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "com.vivaldi.vivaldi",
                        "com.operasoftware.opera", "com.operasoftware.operagx", "app.zen-browser.zen", "org.chromium.chromium",
                        "com.kagi.kagimacos", "ai.perplexity.comet", "net.imput.helium", "com.sigmaos.sigmaos.macos"]
        let mail = ["com.apple.mail", "com.microsoft.outlook", "ch.protonmail.desktop", "com.readdle.smartemail-mac",
                    "com.readdle.sparkdesktop", "com.superhuman.electron", "it.bloop.airmail2", "com.mimestream.mimestream",
                    "com.google.gmail", "io.canarymail.mac", "com.hey.app.desktop", "org.mozilla.thunderbird", "com.tutanota.desktop"]
        let chat = ["com.apple.mobilesms", "com.tinyspeck.slackmacgap", "com.hnc.discord", "com.hnc.discordptb", "net.whatsapp.whatsapp",
                    "desktop.whatsapp", "ru.keepcoder.telegram", "com.tdesktop.telegram", "org.telegram.desktop", "com.microsoft.teams2",
                    "com.microsoft.teams", "com.facebook.archon", "com.facebook.archon.developerid", "org.whispersystems.signal-desktop",
                    "im.riot.app", "com.automattic.beeper.desktop", "com.beeper.beeper"]
        let notes = ["com.apple.notes", "md.obsidian", "net.shinyfrog.bear", "notion.id", "com.lukilabs.lukiapp", "com.electron.logseq",
                     "com.microsoft.onenote.mac", "com.evernote.evernote", "com.reflect.app", "com.capacities.app", "app.tana.desktop"]
        let writing = ["com.apple.pages", "com.apple.iwork.pages", "com.microsoft.word", "com.ulyssesapp.mac", "pro.writer.mac",
                       "com.literatureandlatte.scrivener3", "com.apple.textedit"]
        let code = ["com.apple.dt.xcode", "com.microsoft.vscode", "com.microsoft.vscodeinsiders", "com.todesktop.230313mzl4w4u92",
                    "dev.zed.zed", "com.sublimetext.4", "com.panic.nova", "com.exafunction.windsurf"]
        let terminals = ["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp-stable",
                         "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm", "com.cmuxterm.app"]
        if browsers.contains(id) { return .browser }
        if mail.contains(id) { return .mail }
        if chat.contains(id) { return .chat }
        if notes.contains(id) { return .notes }
        if writing.contains(id) { return .writing }
        if code.contains(id) || id.hasPrefix("com.jetbrains.") { return .code }
        if terminals.contains(id) { return .terminal }
        if id == "com.apple.finder" { return .finder }
        return .other
    }

    /// Reads the app's focused window and selection. Bounded: a hung app costs at most a moment.
    nonisolated static func read(pid: pid_t, bundleID: String?, appName: String, bundlePath: String?) -> AppContext {
        let kind = kind(of: bundleID)
        var c = AppContext(pid: pid, bundleID: bundleID, appName: appName, bundlePath: bundlePath, kind: kind)
        guard AXIsProcessTrusted() else { return c }
        SelectionText.exposeElectron(pid: pid, bundlePath: bundlePath)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)

        if let focused: AXUIElement = AXReader.value(app, kAXFocusedUIElementAttribute),
           let selected: String = AXReader.value(focused, kAXSelectedTextAttribute),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            c.selection = String(selected.prefix(8_000))
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success {
                c.selectionEditable = settable.boolValue
            }
            // A web page's own text isn't settable even where the attribute claims it is.
            let role: String = AXReader.value(focused, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" { c.selectionEditable = false }
        }

        guard let window: AXUIElement = AXReader.value(app, kAXFocusedWindowAttribute) ?? AXReader.value(app, kAXMainWindowAttribute) else { return c }
        c.windowTitle = AXReader.value(window, kAXTitleAttribute)
        if let document: String = AXReader.value(window, kAXDocumentAttribute), let url = URL(string: document) {
            if url.isFileURL { c.filePath = url.path } else if url.scheme?.hasPrefix("http") == true { c.url = url }
        }
        if kind == .browser, c.url == nil { c.url = webAreaURL(in: window) }
        if kind == .finder {
            switch automationPermission("com.apple.finder", ask: false) {
            case noErr: c.files = finderSelection()
            case OSStatus(errAEEventWouldRequireUserConsent): c.needsFinderPermission = true
            default: break // turned down: Finder gets the folder's actions only
            }
        }
        return c
    }

    /// Whether NotchApp may send Apple events to an app (it has to be running); `ask` shows macOS's
    /// prompt when it hasn't been decided. Blocks while the prompt is up: call it off the main thread.
    nonisolated static func automationPermission(_ bundleID: String, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }

    /// What's selected in Finder (it doesn't say through Accessibility). NotchApp already has
    /// Finder's permission for emptying the Trash.
    private nonisolated static func finderSelection() -> [URL] {
        let script = """
        tell application "Finder"
            set out to ""
            set picked to selection
            if (count of picked) > 50 then return ""
            repeat with f in picked
                set out to out & POSIX path of (f as alias) & linefeed
            end repeat
            return out
        end tell
        """
        let result = Shell.runSync("/usr/bin/osascript", ["-e", script], timeout: 2)
        guard result.ok else { return [] }
        return result.out.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// The page's address: the web area's own, else the address bar's. Some browsers (Vivaldi)
    /// draw their own interface as a web page too, so that one is looked through, not taken.
    private nonisolated static func webAreaURL(in window: AXUIElement) -> URL? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var head = 0
        var addressBar: URL?
        let deadline = Date().addingTimeInterval(0.25)
        while head < queue.count, head < 1_200, Date() < deadline {
            let (element, depth) = queue[head]
            head += 1
            let role: String = AXReader.value(element, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" {
                if let url: URL = AXReader.value(element, "AXURL") {
                    if url.scheme?.hasPrefix("http") == true { return url }
                } else if addressBar != nil {
                    continue // a page with no address: nothing better inside it
                }
            } else if role == "AXTextField", addressBar == nil, let value: String = AXReader.value(element, kAXValueAttribute) {
                addressBar = addressURL(value)
            }
            guard depth < 30, let children: [AXUIElement] = AXReader.value(element, kAXChildrenAttribute) else { continue }
            queue += children.map { ($0, depth + 1) }
        }
        return addressBar
    }

    /// "youtube.com/watch?v=…" or "https://…" in an address bar, as a web address.
    private nonisolated static func addressURL(_ value: String) -> URL? {
        let t = value.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if let url = URL(string: t), url.scheme?.hasPrefix("http") == true, url.host() != nil { return url }
        guard t.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+(/|$)"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return URL(string: "https://" + t)
    }
}

/// What the notch offers for the app in front before anything is typed: things to do with the
/// selection, actions for the kind of app (a page in a browser, an email, a terminal), and the
/// app's most useful menu items. Shown as a row under the empty search bar, and ranked into the
/// suggestions while typing.
@MainActor
final class AppActions: ObservableObject {
    static let shared = AppActions()

    @Published private(set) var context: AppContext?
    /// Most fitting first; the row shows as many as fit.
    @Published private(set) var items: [Command] = []
    /// Runs the nth action (⌘1…⌘5) when the search tab can; set while it's showing.
    var shortcut: ((Int) -> Bool)?
    private var generation = 0
    private var lastRead: (pid: pid_t, at: Date)?

    // MARK: - As a Glance

    /// Actions to keep beside the closed notch while their app is in front: bundle ID → action keys,
    /// in the order they were starred. Saved.
    @Published private(set) var stars: [String: [String]] {
        didSet { UserDefaults.standard.set(stars, forKey: "appActionGlances") }
    }
    /// The starred actions the app in front offers right now (a page without a video has no Download).
    @Published private(set) var glanceActions: [Command] = []
    /// How many glyphs the App Actions Glance draws, for its width.
    nonisolated(unsafe) static var glanceCount = 0
    static let starsPerApp = 3
    private var watch: Timer?

    private init() {
        stars = (UserDefaults.standard.dictionary(forKey: "appActionGlances") as? [String: [String]]) ?? [:]
    }

    func isStarred(_ command: Command) -> Bool {
        guard let id = context?.bundleID else { return false }
        return stars[id]?.contains(command.stableKey) == true
    }

    func canStar(_ command: Command) -> Bool {
        guard let id = context?.bundleID else { return false }
        if case .template = command.action { return false }
        return isStarred(command) || (stars[id]?.count ?? 0) < Self.starsPerApp
    }

    /// Stars an action as a Glance for the app in front (or takes it off), pinning the App Actions
    /// Glance the first time.
    func toggleStar(_ command: Command) {
        guard let id = context?.bundleID else { return }
        var keys = stars[id] ?? []
        if let i = keys.firstIndex(of: command.stableKey) { keys.remove(at: i) } else if keys.count < Self.starsPerApp { keys.append(command.stableKey) }
        stars[id] = keys.isEmpty ? nil : keys
        if !keys.isEmpty { LiveActivities.shared.pin(.appAction) }
        if stars.isEmpty { LiveActivities.shared.unpin(.appAction) }
        updateGlance()
    }

    /// Keeps the Glance current: a read when another app comes to the front, and every few seconds
    /// while one with starred actions stays there (a new page, a new selection).
    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppActions.shared.frontmostChanged() }
        }
        frontmostChanged()
    }

    private func frontmostChanged() {
        watch?.invalidate()
        watch = nil
        guard let app = Self.frontmostOtherApp(), let id = app.bundleIdentifier, stars[id] != nil else {
            if !glanceActions.isEmpty { setGlance([]) }
            return
        }
        MenuSearch.shared.prepare()
        prepare()
        watch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                // While the notch is open, its own reads keep things fresh.
                guard NotchPresenter.shared.primary?.isOpen != true else { return }
                AppActions.shared.prepare()
            }
        }
    }

    private func updateGlance() {
        guard let context, let id = context.bundleID, let keys = stars[id],
              Self.frontmostOtherApp()?.processIdentifier == context.pid else { return setGlance([]) }
        setGlance(keys.compactMap { key in items.first { $0.stableKey == key } })
    }

    private func setGlance(_ actions: [Command]) {
        guard actions != glanceActions else { return }
        Self.glanceCount = actions.count
        glanceActions = actions
    }

    /// A click on one of the Glance's glyphs: questions and plans open the notch for their answer;
    /// the rest just happen, with a word from the notch.
    func runGlance(_ command: Command, in vm: NotchViewModel) {
        switch command.action {
        case .askScreen, .planFromScreen, .aiCommand, .translate:
            vm.open(tab: .ask, takeKeyboard: false, reason: .click)
            CommandCenter.shared.run([command])
        default:
            let before = CommandCenter.shared.confirmation?.id
            CommandCenter.shared.run([command])
            if let done = CommandCenter.shared.confirmation, done.id != before {
                ActivityCenter.shared.show(.notice(title: done.text, detail: context?.appName ?? "", icon: done.icon,
                                                   tone: done.failed ? .warning : .success), for: 2.5)
            }
        }
    }

    /// Reads the app in front (in the background) and rebuilds the actions.
    func prepare() {
        guard let app = Self.frontmostOtherApp() else { return reset() }
        let pid = app.processIdentifier
        if let lastRead, lastRead.pid == pid, Date().timeIntervalSince(lastRead.at) < 0.5 { return }
        // Another app: its actions only. The same app keeps the last ones up (they're usually still
        // right) until the fresh read lands, a moment into the opening.
        if context?.pid != pid { reset() }
        lastRead = (pid, Date())
        generation += 1
        let generation = generation
        let bundleID = app.bundleIdentifier, name = app.localizedName ?? "App", path = app.bundleURL?.path
        Task.detached(priority: .userInitiated) {
            let context = AppContext.read(pid: pid, bundleID: bundleID, appName: name, bundlePath: path)
            await MainActor.run {
                let actions = AppActions.shared
                guard actions.generation == generation else { return }
                actions.context = context
                actions.rebuild()
            }
        }
    }

    /// The menus arrived (or the model became ready): the menu items and AI actions can join in.
    func refresh() {
        guard context != nil else { return }
        rebuild()
    }

    func reset() {
        generation += 1
        lastRead = nil
        context = nil
        if !items.isEmpty { items = [] }
        updateGlance()
    }

    /// App actions matching what's typed (every word in the title), for the suggestion list.
    /// AI Commands and menu items are left out: the list finds those on its own.
    func matches(_ query: String, limit: Int) -> [Command] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard query.count >= 3, !words.isEmpty else { return [] }
        return items.filter { command in
            switch command.action {
            case .aiCommand, .menuItem, .template: return false
            default: return words.allSatisfy(command.title.lowercased().contains)
            }
        }
        .prefix(limit).map { $0 }
    }

    private func rebuild() {
        guard let context else { return }
        let new = Self.actions(for: context)
        if new != items { items = new }
        updateGlance()
    }

    private static func frontmostOtherApp() -> NSRunningApplication? {
        FrontmostTracker.shared.userApp
    }

    // MARK: - Building the actions

    static func actions(for c: AppContext) -> [Command] {
        let ai = AssistantStore.shared.aiAvailable
        let screen = ai && AppSettings.shared.screenQuestions
        var out: [Command] = []
        if let selection = c.selection?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty {
            out += selectionActions(selection, editable: c.selectionEditable, in: c, ai: ai)
            // One for the app too, in case the selection was left over.
            out += AppPack.actions(for: c, screen: screen).prefix(1)
        } else {
            out += AppPack.actions(for: c, screen: screen)
            out += AppPack.documentActions(c)
            out += MenuSearch.shared.featured(pid: c.pid, limit: 2).map { ref in
                Command(action: .menuItem(ref), title: ref.item.title.replacingOccurrences(of: "…", with: ""),
                        subtitle: ([ref.appName] + ref.item.path).joined(separator: " › ") + (ref.item.shortcut.map { "  \($0)" } ?? ""),
                        icon: "filemenu.and.selection", verb: "Run")
            }
        }
        // The same thing twice (a menu's "Copy Link" beside ours, or one menu item reached two ways) only once.
        var seen = Set<String>()
        return out.filter { command in
            var keys = [command.title.lowercased()]
            if case .menuItem(let ref) = command.action { keys.append("menu:" + (ref.item.path + [ref.item.title]).joined(separator: "›")) }
            guard keys.allSatisfy({ !seen.contains($0) }) else { return false }
            keys.forEach { seen.insert($0) }
            return true
        }
    }

    /// Selected text: put an AI Command to work on it, and act on what's in it (a date, an address, a list).
    private static func selectionActions(_ s: String, editable: Bool, in c: AppContext, ai: Bool) -> [Command] {
        var out: [Command] = []
        let store = AICommandStore.shared
        func aiCommand(_ command: AICommand) -> Command {
            Command(action: .aiCommand(command.id), title: command.name,
                    subtitle: command.output == .replace ? "Replaces the selection in \(c.appName)" : "On the selected text",
                    icon: command.icon, verb: command.output == .replace ? "Replace" : "Run")
        }
        // Text you're writing: fixing it is the likeliest thing.
        if ai, editable, let fix = store.commands.first(where: { $0.output == .replace }) { out.append(aiCommand(fix)) }

        // What's in it, as the clipboard sees copies (the general "add to notes / search" ones aside).
        let found = ClipActions.text(s).filter { !["note", "search", "task"].contains($0.id) }
        // Short names for the row; the clipboard's longer ones ("Add to Calendar: Lunch, Fri 1 PM") say the rest.
        let short = ["event": "Add to Calendar", "mail": "Write email", "call": "Call", "maps": "Show in Maps",
                     "openlink": "Open link", "rgb": "Copy as RGB"]
        out += found.prefix(2).map { action in
            Command(action: .perform(.init(id: "clip." + action.id, run: action.run)), title: short[action.id] ?? action.title,
                    subtitle: action.title, icon: action.icon, verb: "Run")
        }

        if ai {
            if let language = foreignLanguage(s) {
                out.append(Command(action: .translate(s, to: language), title: "Translate to \(language)",
                                   subtitle: String(s.prefix(80)), icon: "character.bubble", verb: "Translate"))
            }
            let wanted = s.count > 600 ? "summar" : "explain"
            if let read = store.commands.first(where: { $0.output == .show && $0.name.lowercased().hasPrefix(wanted) })
                ?? store.commands.first(where: { $0.output == .show }) {
                out.append(aiCommand(read))
            }
        }
        if AppSettings.shared.tasksEnabled, let task = ClipActions.text(s).first(where: { $0.id == "task" }) {
            out.append(Command(action: .perform(.init(id: "clip.task", run: task.run)), title: "Add to Tasks",
                               subtitle: "From the selection", icon: task.icon, verb: "Add"))
        }
        if ai, store.commands.count > 1 {
            out.append(Command(action: .template("ai "), title: "AI Commands", subtitle: "Everything you can do with the selection",
                               icon: "sparkles", verb: "Show"))
        }
        return out
    }

    /// The language the text is in, by name ("French"), when it isn't one the user reads.
    private static func foreignLanguage(_ s: String) -> String? {
        guard s.count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(s.prefix(1000)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.8 else { return nil }
        let mine = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        guard !mine.contains(language.rawValue) else { return nil }
        let target = mine.first ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: target)
    }

}
