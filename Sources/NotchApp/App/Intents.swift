import AppIntents
import AppKit

/// NotchApp's actions for the Shortcuts app, Siri and Spotlight: what other automations can ask of
/// the notch (start a timer, show a Banner, put files on the Shelf, ask a question…). Built from
/// the same commands the search bar runs. build.sh extracts their metadata into the app bundle,
/// which is how Shortcuts finds them (Xcode would do this itself).

struct StartTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Timer"
    static let description = IntentDescription("Starts NotchApp's timer for a number of minutes.")
    @Parameter(title: "Minutes", default: 25, inclusiveRange: (1, 600)) var minutes: Int

    @MainActor func perform() async throws -> some IntentResult {
        CommandCenter.shared.run([Command(action: .startTimer(minutes: minutes), title: "Timer", icon: "timer")])
        return .result()
    }
}

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription("Adds a task to NotchApp's list. A time in it (\"call mom tomorrow 3pm\") becomes its due date.")
    @Parameter(title: "Task") var task: String

    @MainActor func perform() async throws -> some IntentResult {
        CommandCenter.shared.run([CommandParser.addTasks([task])])
        return .result()
    }
}

struct ShowBannerIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Banner"
    static let description = IntentDescription("Drops a Banner down from the notch with your words, for a moment.")
    @Parameter(title: "Title") var title: String
    @Parameter(title: "Detail", default: "") var detail: String
    @Parameter(title: "Symbol", description: "An SF Symbol's name, like bell.fill", default: "bell.fill") var symbol: String

    @MainActor func perform() async throws -> some IntentResult {
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : "bell.fill"
        ActivityCenter.shared.show(.notice(title: title, detail: detail, icon: icon, tone: .info), for: 4)
        return .result()
    }
}

struct AddToShelfIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Shelf"
    static let description = IntentDescription("Puts files on NotchApp's Shelf, ready to drag anywhere.")
    @Parameter(title: "Files") var files: [IntentFile]

    @MainActor func perform() async throws -> some IntentResult {
        let urls = files.compactMap { file -> URL? in
            if let url = file.fileURL { return url }
            // Made by an earlier action, with no file of its own yet: kept with the Shelf's files.
            let target = ShelfStore.keptFolder.appendingPathComponent(file.filename)
            return (try? file.data.write(to: target)) != nil ? target : nil
        }
        ShelfStore.shared.add(urls)
        return .result()
    }
}

struct AskIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask NotchApp"
    static let description = IntentDescription("Opens the notch and asks a question, as if typed in its search bar.")
    @Parameter(title: "Question") var question: String

    @MainActor func perform() async throws -> some IntentResult {
        NotchPresenter.shared.primary?.open(tab: .ask, takeKeyboard: false, reason: .keyboard)
        AssistantStore.shared.run(question)
        return .result()
    }
}

struct CaptionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Live Captions"
    static let description = IntentDescription("Turns live captions under the notch on or off.")
    @Parameter(title: "On", default: true) var on: Bool

    @MainActor func perform() async throws -> some IntentResult {
        if on { LiveCaptions.shared.startCaptions() } else { LiveCaptions.shared.stopCaptions() }
        return .result()
    }
}

struct KeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep Mac Awake"
    static let description = IntentDescription("Keeps the Mac awake for a while (0 minutes: until turned off), or stops.")
    @Parameter(title: "Minutes", default: 60) var minutes: Int
    @Parameter(title: "Stop instead", default: false) var stop: Bool

    @MainActor func perform() async throws -> some IntentResult {
        if stop { KeepAwake.shared.stop() } else { KeepAwake.shared.start(minutes > 0 ? .minutes(minutes) : .indefinitely) }
        return .result()
    }
}

struct CleanLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Link"
    static let description = IntentDescription("Takes the tracking off a link (utm_…, fbclid, si…) and unwraps redirects.")
    @Parameter(title: "Link") var link: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: LinkCleaner.clean(link)?.link ?? link)
    }
}

enum GlanceChoice: String, AppEnum {
    case music, timer, battery, cpu, memory, network, weather, nextEvent, duo, rings, focus, shortcuts, unread, countdown, worldClock

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Glance"
    static let caseDisplayRepresentations: [GlanceChoice: DisplayRepresentation] = [
        .music: "Now Playing", .timer: "Timer", .battery: "Battery", .cpu: "CPU", .memory: "Memory", .network: "Network",
        .weather: "Weather", .nextEvent: "Next Event", .duo: "Duo", .rings: "Stats Rings", .focus: "Focus",
        .shortcuts: "Shortcuts", .unread: "Unread", .countdown: "Countdown", .worldClock: "World Clock",
    ]
}

struct GlanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Show or Hide a Glance"
    static let description = IntentDescription("Pins a Glance beside the notch, or takes it off.")
    @Parameter(title: "Glance") var glance: GlanceChoice
    @Parameter(title: "Show", default: true) var show: Bool

    @MainActor func perform() async throws -> some IntentResult {
        guard let item = LiveItem(rawValue: glance.rawValue) else { return .result() }
        if show { LiveActivities.shared.pin(item) } else { LiveActivities.shared.unpin(item) }
        return .result()
    }
}

enum TabChoice: String, AppEnum {
    case ask, home, shelf, tasks, timer, controls, stats, tools

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tab"
    static let caseDisplayRepresentations: [TabChoice: DisplayRepresentation] = [
        .ask: "Search", .home: "Home", .shelf: "Shelf", .tasks: "Tasks", .timer: "Timer", .controls: "Controls",
        .stats: "Stats", .tools: "Tools",
    ]
}

struct OpenTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Notch"
    static let description = IntentDescription("Opens the notch on one of its tabs.")
    @Parameter(title: "Tab", default: .home) var tab: TabChoice

    @MainActor func perform() async throws -> some IntentResult {
        NotchPresenter.shared.primary?.open(tab: NotchTab(rawValue: tab.rawValue), takeKeyboard: tab == .ask, reason: .keyboard)
        return .result()
    }
}

/// Ready-made phrases for Siri and Spotlight, no setup needed.
struct NotchAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartTimerIntent(), phrases: ["Start a timer in \(.applicationName)", "Start a \(.applicationName) timer"],
                    shortTitle: "Start Timer", systemImageName: "timer")
        AppShortcut(intent: CaptionsIntent(), phrases: ["Turn on captions in \(.applicationName)", "Live captions in \(.applicationName)"],
                    shortTitle: "Live Captions", systemImageName: "captions.bubble.fill")
        AppShortcut(intent: AskIntent(), phrases: ["Ask \(.applicationName)"], shortTitle: "Ask", systemImageName: "sparkle.magnifyingglass")
        AppShortcut(intent: AddTaskIntent(), phrases: ["Add a task in \(.applicationName)"], shortTitle: "Add Task", systemImageName: "checklist")
    }
}
