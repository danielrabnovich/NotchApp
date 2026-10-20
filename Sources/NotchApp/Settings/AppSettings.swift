import AppKit
import SwiftUI

/// All user preferences, persisted to UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum OpenMode: String, CaseIterable, Identifiable {
        case hover, click
        var id: String { rawValue }
        var label: String { self == .hover ? "Hover" : "Click" }
    }

    enum DisplayMode: String, CaseIterable, Identifiable {
        case notched, main, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .notched: "Notched display"
            case .main: "Primary display"
            case .all: "All displays"
            }
        }
    }

    enum AccentMode: String, CaseIterable, Identifiable {
        case albumArt, custom
        var id: String { rawValue }
        var label: String { self == .albumArt ? "Match album art" : "Custom color" }
    }

    /// When unpinned shelf files (quick drops on their way to another app) leave the shelf.
    enum ShelfExpiry: String, CaseIterable, Identifiable {
        case hour, endOfDay, never
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hour: "After an hour"
            case .endOfDay: "At the end of the day"
            case .never: "Never"
            }
        }
    }

    /// How everything moves: the notch opening, pages sliding, panes and lists. One choice for
    /// all of it (see `Motion`).
    enum AnimationStyle: String, CaseIterable, Identifiable {
        case smooth, snappy, bouncy
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// The open notch: black throughout, or black at the notch melting into glass below it.
    enum NotchMaterial: String, CaseIterable, Identifiable {
        case black, glass
        var id: String { rawValue }
        var label: String { self == .black ? "Black" : "Dynamic Glass" }
        static var isAvailable: Bool { if #available(macOS 26, *) { true } else { false } }
    }

    /// How much of the open notch is glass, as iOS lets you choose: never by frosting it, only by
    /// how far the black reaches, how dark the shade over the glass is and how deep its rim bends.
    enum GlassLevel: String, CaseIterable, Identifiable {
        case tinted, balanced, airy, clear
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// What plays around the search bar: Apple Intelligence's colours, a white shimmer along its
    /// edge, or nothing at all.
    enum SearchBarEffect: String, CaseIterable, Identifiable {
        case glow, shimmer, none
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    private let defaults = UserDefaults.standard

    // General
    @Published var openMode: OpenMode { didSet { defaults.set(openMode.rawValue, forKey: "openMode") } }
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    /// The screen the notch opens on: a tab's name, or "last" for wherever it was left.
    @Published var openTo: String { didSet { defaults.set(openTo, forKey: "openTo") } }
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") } }
    @Published var showFakeNotch: Bool { didSet { defaults.set(showFakeNotch, forKey: "showFakeNotch") } }
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    @Published var hasLaunchedBefore: Bool { didSet { defaults.set(hasLaunchedBefore, forKey: "hasLaunchedBefore") } }

    // Appearance
    @Published var accentMode: AccentMode { didSet { defaults.set(accentMode.rawValue, forKey: "accentMode") } }
    @Published var customAccentHex: String { didSet { defaults.set(customAccentHex, forKey: "customAccentHex") } }
    @Published var animationStyle: AnimationStyle { didSet { defaults.set(animationStyle.rawValue, forKey: "animationStyle") } }
    @Published var showShadow: Bool { didSet { defaults.set(showShadow, forKey: "showShadow") } }
    @Published var notchMaterial: NotchMaterial { didSet { defaults.set(notchMaterial.rawValue, forKey: "notchMaterial") } }
    @Published var glassLevel: GlassLevel { didSet { defaults.set(glassLevel.rawValue, forKey: "glassLevel") } }
    @Published var searchBarEffect: SearchBarEffect { didSet { defaults.set(searchBarEffect.rawValue, forKey: "searchBarEffect") } }
    /// Glass only where the system can draw it.
    var usesGlass: Bool { notchMaterial == .glass && NotchMaterial.isAvailable }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    @Published var glanceDensity: GlanceDensity { didSet { defaults.set(glanceDensity.rawValue, forKey: "glanceDensity") } }
    @Published var alertLevel: AlertLevel { didSet { defaults.set(alertLevel.rawValue, forKey: "alertLevel") } }

    /// Which heads-ups drop down under the notch. Flashes (volume, brightness, charging) follow
    /// their own switches.
    enum AlertLevel: String, CaseIterable, Identifiable {
        case all, important, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All"
            case .important: "Important"
            case .none: "None"
            }
        }
    }

    // Media
    @Published var musicEnabled: Bool { didSet { defaults.set(musicEnabled, forKey: "musicEnabled") } }
    @Published var musicLiveActivity: Bool { didSet { defaults.set(musicLiveActivity, forKey: "musicLiveActivity") } }
    @Published var showVisualizer: Bool { didSet { defaults.set(showVisualizer, forKey: "showVisualizer") } }

    // HUD
    @Published var volumeHUD: Bool { didSet { defaults.set(volumeHUD, forKey: "volumeHUD") } }
    @Published var brightnessHUD: Bool { didSet { defaults.set(brightnessHUD, forKey: "brightnessHUD") } }

    // Battery
    @Published var chargingAnimation: Bool { didSet { defaults.set(chargingAnimation, forKey: "chargingAnimation") } }

    // Shelf
    @Published var shelfEnabled: Bool { didSet { defaults.set(shelfEnabled, forKey: "shelfEnabled") } }
    @Published var screenshotCatcher: Bool { didSet { defaults.set(screenshotCatcher, forKey: "screenshotCatcher") } }
    @Published var airDropZone: Bool { didSet { defaults.set(airDropZone, forKey: "airDropZone") } }
    /// Fresh drops wait in a stack under the collapsed notch, to drag straight out.
    @Published var shelfStack: Bool { didSet { defaults.set(shelfStack, forKey: "shelfStack") } }
    /// Whatever was just added to the shelf goes on the clipboard too, ready to paste.
    @Published var copyShelfAdds: Bool { didSet { defaults.set(copyShelfAdds, forKey: "copyShelfAdds") } }
    /// Files on the shelf go by a made-up name, and leave under it (a copy; the original keeps its own).
    @Published var shelfRandomNames: Bool { didSet { defaults.set(shelfRandomNames, forKey: "shelfRandomNames") } }
    /// Copied links lose their tracking (utm_…, fbclid, si…) on the clipboard itself.
    @Published var cleanLinks: Bool { didSet { defaults.set(cleanLinks, forKey: "cleanLinks") } }
    /// Caught screenshots are thrown away 15 minutes after they're taken, or a minute after a paste.
    @Published var screenshotCleanup: Bool { didSet { defaults.set(screenshotCleanup, forKey: "screenshotCleanup") } }
    @Published var shelfExpiry: ShelfExpiry { didSet { defaults.set(shelfExpiry.rawValue, forKey: "shelfExpiry") } }

    // Tasks
    @Published var tasksEnabled: Bool { didSet { defaults.set(tasksEnabled, forKey: "tasksEnabled") } }
    @Published var showTaskCount: Bool { didSet { defaults.set(showTaskCount, forKey: "showTaskCount") } }

    // Timer
    @Published var timerEnabled: Bool { didSet { defaults.set(timerEnabled, forKey: "timerEnabled") } }
    @Published var timerLiveActivity: Bool { didSet { defaults.set(timerLiveActivity, forKey: "timerLiveActivity") } }
    @Published var timerSounds: Bool { didSet { defaults.set(timerSounds, forKey: "timerSounds") } }
    @Published var pomodoroAutoStart: Bool { didSet { defaults.set(pomodoroAutoStart, forKey: "pomodoroAutoStart") } }

    // Notes, downloads, mixer
    @Published var notesEnabled: Bool { didSet { defaults.set(notesEnabled, forKey: "notesEnabled") } }
    @Published var downloadsEnabled: Bool { didSet { defaults.set(downloadsEnabled, forKey: "downloadsEnabled") } }
    @Published var downloadAlerts: Bool { didSet { defaults.set(downloadAlerts, forKey: "downloadAlerts") } }
    @Published var taildropZone: Bool { didSet { defaults.set(taildropZone, forKey: "taildropZone") } }
    @Published var taildropReceive: Bool { didSet { defaults.set(taildropReceive, forKey: "taildropReceive") } }
    @Published var taildropToShelf: Bool { didSet { defaults.set(taildropToShelf, forKey: "taildropToShelf") } }
    @Published var mixerEnabled: Bool { didSet { defaults.set(mixerEnabled, forKey: "mixerEnabled") } }
    @Published var controlsEnabled: Bool { didSet { defaults.set(controlsEnabled, forKey: "controlsEnabled") } }
    @Published var updateChecks: Bool { didSet { defaults.set(updateChecks, forKey: "updateChecks") } }
    @Published var updateChecksApps: Bool { didSet { defaults.set(updateChecksApps, forKey: "updateChecksApps") } }
    @Published var updateAlerts: Bool { didSet { defaults.set(updateAlerts, forKey: "updateAlerts") } }
    @Published var keepAwakeDisplay: Bool { didSet { defaults.set(keepAwakeDisplay, forKey: "keepAwakeDisplay") } }
    @Published var keepAwakeLidClosed: Bool { didSet { defaults.set(keepAwakeLidClosed, forKey: "keepAwakeLidClosed") } }
    @Published var keepAwakeBatteryFloor: Int { didSet { defaults.set(keepAwakeBatteryFloor, forKey: "keepAwakeBatteryFloor") } }
    @Published var reverseMouseScroll: Bool { didSet { defaults.set(reverseMouseScroll, forKey: "reverseMouseScroll") } }
    @Published var threeFingerMiddleClick: Bool { didSet { defaults.set(threeFingerMiddleClick, forKey: "threeFingerMiddleClick") } }
    @Published var cameraMirrorEnabled: Bool { didSet { defaults.set(cameraMirrorEnabled, forKey: "cameraMirrorEnabled") } }
    @Published var hotKeysEnabled: Bool { didSet { defaults.set(hotKeysEnabled, forKey: "hotKeysEnabled") } }
    @Published var hotKeyModifiers: HotKeys.Modifiers { didSet { defaults.set(hotKeyModifiers.rawValue, forKey: "hotKeyModifiers") } }
    /// Shortcuts rebound one by one, by action; the rest use the shared modifiers and their default key.
    @Published var hotKeyOverrides: [String: HotKeys.Combo] {
        didSet { defaults.set(try? JSONEncoder().encode(hotKeyOverrides), forKey: "hotKeyOverrides") }
    }
    /// The Shelf tab's keys (paste or open, copy, remove…) rebound one by one; the rest keep their defaults.
    @Published var shelfKeyOverrides: [String: HotKeys.Combo] {
        didSet { defaults.set(try? JSONEncoder().encode(shelfKeyOverrides), forKey: "shelfKeyOverrides") }
    }

    // Tools
    @Published var toolsEnabled: Bool { didSet { defaults.set(toolsEnabled, forKey: "toolsEnabled") } }
    @Published var clipboardHistory: Bool { didSet { defaults.set(clipboardHistory, forKey: "clipboardHistory") } }
    /// Other apps' notifications in the notch, with a reply.
    @Published var notificationMirror: NotificationMirror.Mode {
        didSet {
            defaults.set(notificationMirror.rawValue, forKey: "notificationMirror")
            if oldValue != notificationMirror { NotificationMirror.shared.apply() }
        }
    }
    @Published var deviceBatteryAlerts: Bool { didSet { defaults.set(deviceBatteryAlerts, forKey: "deviceBatteryAlerts") } }
    @Published var privacyAlerts: Bool { didSet { defaults.set(privacyAlerts, forKey: "privacyAlerts") } }
    @Published var lowDiskAlerts: Bool { didSet { defaults.set(lowDiskAlerts, forKey: "lowDiskAlerts") } }
    @Published var speedTestLiveActivity: Bool { didSet { defaults.set(speedTestLiveActivity, forKey: "speedTestLiveActivity") } }
    @Published var downloadLiveActivity: Bool { didSet { defaults.set(downloadLiveActivity, forKey: "downloadLiveActivity") } }
    @Published var convertToShelf: Bool { didSet { defaults.set(convertToShelf, forKey: "convertToShelf") } }
    @Published var screenshotSearch: Bool { didSet { defaults.set(screenshotSearch, forKey: "screenshotSearch") } }
    @Published var devServerAlerts: Bool { didSet { defaults.set(devServerAlerts, forKey: "devServerAlerts") } }
    @Published var connectionAlerts: Bool { didSet { defaults.set(connectionAlerts, forKey: "connectionAlerts") } }

    @Published var videoDownloadsToShelf: Bool { didSet { defaults.set(videoDownloadsToShelf, forKey: "videoDownloadsToShelf") } }
    /// Largest video height for one-click downloads; 0 = best available.
    @Published var videoQuality: Int { didSet { defaults.set(videoQuality, forKey: "videoQuality") } }

    // Agents
    @Published var agentsEnabled: Bool { didSet { defaults.set(agentsEnabled, forKey: "agentsEnabled") } }
    @Published var agentAlerts: Bool { didSet { defaults.set(agentAlerts, forKey: "agentAlerts") } }
    /// Plan chosen per agent tool (Claude Code, Codex…); empty means use the detected one.
    @Published var agentPlans: [String: String] { didSet { defaults.set(agentPlans, forKey: "agentPlans") } }
    @Published var agentsKeepAwake: Bool { didSet { defaults.set(agentsKeepAwake, forKey: "agentsKeepAwake") } }

    // Stats
    @Published var statsEnabled: Bool { didSet { defaults.set(statsEnabled, forKey: "statsEnabled") } }
    @Published var useFahrenheit: Bool { didSet { defaults.set(useFahrenheit, forKey: "useFahrenheit") } }

    // Assistant (Ollama)
    @Published var assistantEnabled: Bool { didSet { defaults.set(assistantEnabled, forKey: "assistantEnabled") } }
    @Published var ollamaURL: String { didSet { defaults.set(ollamaURL, forKey: "ollamaURL") } }
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "ollamaModel") } }
    /// Where the intelligence comes from: the local model, or a cloud one with your own key.
    @Published var aiProvider: AIProvider { didSet { defaults.set(aiProvider.rawValue, forKey: "aiProvider") } }
    /// The model picked for each cloud provider, and each one's address (editable for custom servers).
    @Published var cloudModels: [String: String] { didSet { defaults.set(cloudModels, forKey: "cloudModels") } }
    @Published var cloudBaseURLs: [String: String] { didSet { defaults.set(cloudBaseURLs, forKey: "cloudBaseURLs") } }
    /// Screen questions may use the cloud model (sending the captured window); off keeps them on this Mac.
    @Published var cloudScreenQuestions: Bool { didSet { defaults.set(cloudScreenQuestions, forKey: "cloudScreenQuestions") } }

    func cloudModel(for provider: AIProvider) -> String { cloudModels[provider.rawValue] ?? provider.suggestedModel }
    func cloudBaseURL(for provider: AIProvider) -> String {
        let custom = cloudBaseURLs[provider.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? provider.defaultBaseURL : custom
    }
    @Published var systemNotifications: Bool { didSet { defaults.set(systemNotifications, forKey: "systemNotifications") } }
    @Published var imageIndexing: Bool { didSet { defaults.set(imageIndexing, forKey: "imageIndexing") } }
    @Published var homeCity: String { didSet { defaults.set(homeCity, forKey: "homeCity") } }
    /// The World Clock Glance's city (its id in WorldClock.cities).
    @Published var worldClockCity: String { didSet { defaults.set(worldClockCity, forKey: "worldClockCity") } }
    /// The Countdown Glance: what it's to, and when (seconds since 1970; 0 when unset).
    @Published var countdownTitle: String { didSet { defaults.set(countdownTitle, forKey: "countdownTitle") } }
    @Published var countdownDate: Double { didSet { defaults.set(countdownDate, forKey: "countdownDate") } }
    /// "What's the answer to this question" looks at the screen (captured in memory, never saved).
    @Published var screenQuestions: Bool { didSet { defaults.set(screenQuestions, forKey: "screenQuestions") } }

    // Brief & nudges
    @Published var morningBrief: Bool { didSet { defaults.set(morningBrief, forKey: "morningBrief") } }
    @Published var briefHour: Int { didSet { defaults.set(briefHour, forKey: "briefHour") } }
    @Published var dueNudges: Bool { didSet { defaults.set(dueNudges, forKey: "dueNudges") } }
    /// Ramble presses the dictation app's key as it opens, so talking can start straight away.
    @Published var rambleAutoDictate: Bool { didSet { defaults.set(rambleAutoDictate, forKey: "rambleAutoDictate") } }
    /// A call timer and mute button beside the notch during calls, and notes or a follow-up after.
    @Published var meetingMode: Bool { didSet { defaults.set(meetingMode, forKey: "meetingMode") } }
    /// During a call, both sides are turned into text on this Mac, for notes afterwards.
    @Published var transcribeCalls: Bool { didSet { defaults.set(transcribeCalls, forKey: "transcribeCalls") } }
    /// Sounds around you (a doorbell, a knock) while headphones are on.
    @Published var soundAlerts: Bool { didSet { defaults.set(soundAlerts, forKey: "soundAlerts") } }
    /// A progress ring beside the notch while anything downloads, copies, converts or exports.
    @Published var progressGlance: Bool { didSet { defaults.set(progressGlance, forKey: "progressGlance") } }
    @Published var nudgeLeadMinutes: Int { didSet { defaults.set(nudgeLeadMinutes, forKey: "nudgeLeadMinutes") } }

    // Calendar
    @Published var calendarEnabled: Bool { didSet { defaults.set(calendarEnabled, forKey: "calendarEnabled") } }
    /// Put the cursor in the search bar when the notch opens on hover, ready to type.
    @Published var focusSearchOnHover: Bool { didSet { defaults.set(focusSearchOnHover, forKey: "focusSearchOnHover") } }
    /// Where events created from the search bar go (empty = the system default calendar).
    @Published var defaultCalendarID: String { didSet { defaults.set(defaultCalendarID, forKey: "defaultCalendarID") } }
    @Published var meetingAlerts: Bool { didSet { defaults.set(meetingAlerts, forKey: "meetingAlerts") } }
    @Published var meetingAlertMinutes: Int { didSet { defaults.set(meetingAlertMinutes, forKey: "meetingAlertMinutes") } }

    static let addOnKeys = ["calendarEnabled", "timerEnabled", "mixerEnabled", "controlsEnabled", "statsEnabled",
                            "cameraMirrorEnabled", "morningBrief"]

    private init() {
        defaults.register(defaults: [
            "openMode": OpenMode.hover.rawValue,
            "hoverDelay": 0.15,
            "displayMode": DisplayMode.notched.rawValue,
            "showFakeNotch": true,
            "showMenuBarIcon": true,
            "accentMode": AccentMode.albumArt.rawValue,
            "customAccentHex": "#0A84FF",
            "animationStyle": AnimationStyle.smooth.rawValue,
            "showShadow": true,
            "openTo": "ask",
            "notchMaterial": NotchMaterial.glass.rawValue,
            "glassLevel": GlassLevel.balanced.rawValue,
            "searchBarEffect": SearchBarEffect.glow.rawValue,
            "haptics": true,
            "musicEnabled": true,
            "musicLiveActivity": true,
            "showVisualizer": true,
            "volumeHUD": true,
            "brightnessHUD": true,
            "chargingAnimation": true,
            "shelfEnabled": true,
            "screenshotCatcher": true,
            "airDropZone": true,
            "shelfStack": true,
            "copyShelfAdds": true,
            "shelfRandomNames": false,
            "cleanLinks": true,
            "screenshotCleanup": false,
            "shelfExpiry": ShelfExpiry.hour.rawValue,
            "tasksEnabled": true,
            "showTaskCount": true,
            "timerEnabled": false,
            "timerLiveActivity": true,
            "timerSounds": true,
            "pomodoroAutoStart": true,
            "notesEnabled": true,
            "downloadsEnabled": true,
            "downloadAlerts": true,
            "taildropZone": TaildropService.cli != nil,
            "taildropReceive": TaildropService.cli != nil,
            "taildropToShelf": true,
            "mixerEnabled": false,
            "controlsEnabled": false,
            "updateChecks": true,
            "updateChecksApps": true,
            "updateAlerts": true,
            "keepAwakeDisplay": true,
            "keepAwakeLidClosed": false,
            "keepAwakeBatteryFloor": 20,
            "reverseMouseScroll": false,
            "threeFingerMiddleClick": false,
            "cameraMirrorEnabled": false,
            "hotKeysEnabled": true,
            "hotKeyModifiers": HotKeys.Modifiers.controlOption.rawValue,
            "statsEnabled": false,
            "toolsEnabled": false,
            "clipboardHistory": false,
            "notificationMirror": NotificationMirror.Mode.chats.rawValue,
            "deviceBatteryAlerts": true,
            "privacyAlerts": false,
            "lowDiskAlerts": true,
            "devServerAlerts": false,
            "screenshotSearch": true,
            "speedTestLiveActivity": true,
            "downloadLiveActivity": true,
            "convertToShelf": true,
            "connectionAlerts": true,
            "agentsEnabled": false,
            "videoDownloadsToShelf": true,
            "videoQuality": 1080,
            "agentAlerts": true,
            "agentsKeepAwake": true,
            "useFahrenheit": Locale.current.measurementSystem == .us,
            "assistantEnabled": true,
            "ollamaURL": "http://localhost:11434",
            "ollamaModel": OllamaModelCatalog.defaultModel,
            "systemNotifications": true,
            "imageIndexing": true,
            "homeCity": "",
            "worldClockCity": "",
            "countdownTitle": "Launch",
            "countdownDate": 0.0,
            "screenQuestions": true,
            "morningBrief": false,
            "briefHour": 6,
            "dueNudges": true,
            "rambleAutoDictate": false,
            "meetingMode": true,
            "transcribeCalls": false,
            "soundAlerts": false,
            "progressGlance": true,
            "nudgeLeadMinutes": 120,
            "calendarEnabled": false,
            "defaultCalendarID": "",
            "focusSearchOnHover": true,
            "meetingAlerts": true,
            "meetingAlertMinutes": 5,
        ])
        // NotchApp is lean by default: Search, Shelf and Tasks, with music, volume, brightness and
        // charging where a notch app is expected to show them (none asks for a new permission).
        // Everything else is an add-on in Settings → Add-ons. Applied once to existing installs too.
        if !defaults.bool(forKey: "leanDefaultsApplied") {
            for key in Self.addOnKeys { defaults.set(false, forKey: key) }
            defaults.set(true, forKey: "leanDefaultsApplied")
        }
        openMode = OpenMode(rawValue: defaults.string(forKey: "openMode") ?? "") ?? .hover
        hoverDelay = defaults.double(forKey: "hoverDelay")
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .notched
        showFakeNotch = defaults.bool(forKey: "showFakeNotch")
        showMenuBarIcon = defaults.bool(forKey: "showMenuBarIcon")
        hasLaunchedBefore = defaults.bool(forKey: "hasLaunchedBefore")
        accentMode = AccentMode(rawValue: defaults.string(forKey: "accentMode") ?? "") ?? .albumArt
        customAccentHex = defaults.string(forKey: "customAccentHex") ?? "#0A84FF"
        animationStyle = AnimationStyle(rawValue: defaults.string(forKey: "animationStyle") ?? "") ?? .smooth
        showShadow = defaults.bool(forKey: "showShadow")
        openTo = defaults.string(forKey: "openTo") ?? "ask"
        notchMaterial = NotchMaterial(rawValue: defaults.string(forKey: "notchMaterial") ?? "") ?? .glass
        glassLevel = GlassLevel(rawValue: defaults.string(forKey: "glassLevel") ?? "") ?? .balanced
        searchBarEffect = SearchBarEffect(rawValue: defaults.string(forKey: "searchBarEffect") ?? "") ?? .glow
        haptics = defaults.bool(forKey: "haptics")
        glanceDensity = GlanceDensity(rawValue: defaults.string(forKey: "glanceDensity") ?? "") ?? .regular
        alertLevel = AlertLevel(rawValue: defaults.string(forKey: "alertLevel") ?? "") ?? .all
        musicEnabled = defaults.bool(forKey: "musicEnabled")
        musicLiveActivity = defaults.bool(forKey: "musicLiveActivity")
        showVisualizer = defaults.bool(forKey: "showVisualizer")
        volumeHUD = defaults.bool(forKey: "volumeHUD")
        brightnessHUD = defaults.bool(forKey: "brightnessHUD")
        chargingAnimation = defaults.bool(forKey: "chargingAnimation")
        shelfEnabled = defaults.bool(forKey: "shelfEnabled")
        screenshotCatcher = defaults.bool(forKey: "screenshotCatcher")
        airDropZone = defaults.bool(forKey: "airDropZone")
        shelfStack = defaults.bool(forKey: "shelfStack")
        copyShelfAdds = defaults.bool(forKey: "copyShelfAdds")
        shelfRandomNames = defaults.bool(forKey: "shelfRandomNames")
        cleanLinks = defaults.bool(forKey: "cleanLinks")
        screenshotCleanup = defaults.bool(forKey: "screenshotCleanup")
        shelfExpiry = ShelfExpiry(rawValue: defaults.string(forKey: "shelfExpiry") ?? "") ?? .hour
        tasksEnabled = defaults.bool(forKey: "tasksEnabled")
        showTaskCount = defaults.bool(forKey: "showTaskCount")
        timerEnabled = defaults.bool(forKey: "timerEnabled")
        timerLiveActivity = defaults.bool(forKey: "timerLiveActivity")
        timerSounds = defaults.bool(forKey: "timerSounds")
        pomodoroAutoStart = defaults.bool(forKey: "pomodoroAutoStart")
        notesEnabled = defaults.bool(forKey: "notesEnabled")
        downloadsEnabled = defaults.bool(forKey: "downloadsEnabled")
        downloadAlerts = defaults.bool(forKey: "downloadAlerts")
        taildropZone = defaults.bool(forKey: "taildropZone")
        taildropReceive = defaults.bool(forKey: "taildropReceive")
        taildropToShelf = defaults.bool(forKey: "taildropToShelf")
        mixerEnabled = defaults.bool(forKey: "mixerEnabled")
        controlsEnabled = defaults.bool(forKey: "controlsEnabled")
        updateChecks = defaults.bool(forKey: "updateChecks")
        updateChecksApps = defaults.bool(forKey: "updateChecksApps")
        updateAlerts = defaults.bool(forKey: "updateAlerts")
        keepAwakeDisplay = defaults.bool(forKey: "keepAwakeDisplay")
        keepAwakeLidClosed = defaults.bool(forKey: "keepAwakeLidClosed")
        keepAwakeBatteryFloor = defaults.integer(forKey: "keepAwakeBatteryFloor")
        reverseMouseScroll = defaults.bool(forKey: "reverseMouseScroll")
        threeFingerMiddleClick = defaults.bool(forKey: "threeFingerMiddleClick")
        cameraMirrorEnabled = defaults.bool(forKey: "cameraMirrorEnabled")
        hotKeysEnabled = defaults.bool(forKey: "hotKeysEnabled")
        hotKeyModifiers = HotKeys.Modifiers(rawValue: defaults.string(forKey: "hotKeyModifiers") ?? "") ?? .controlOption
        hotKeyOverrides = defaults.data(forKey: "hotKeyOverrides").flatMap { try? JSONDecoder().decode([String: HotKeys.Combo].self, from: $0) } ?? [:]
        shelfKeyOverrides = defaults.data(forKey: "shelfKeyOverrides").flatMap { try? JSONDecoder().decode([String: HotKeys.Combo].self, from: $0) } ?? [:]
        statsEnabled = defaults.bool(forKey: "statsEnabled")
        toolsEnabled = defaults.bool(forKey: "toolsEnabled")
        clipboardHistory = defaults.bool(forKey: "clipboardHistory")
        notificationMirror = NotificationMirror.Mode(rawValue: defaults.string(forKey: "notificationMirror") ?? "") ?? .chats
        deviceBatteryAlerts = defaults.bool(forKey: "deviceBatteryAlerts")
        privacyAlerts = defaults.bool(forKey: "privacyAlerts")
        lowDiskAlerts = defaults.bool(forKey: "lowDiskAlerts")
        devServerAlerts = defaults.bool(forKey: "devServerAlerts")
        screenshotSearch = defaults.bool(forKey: "screenshotSearch")
        speedTestLiveActivity = defaults.bool(forKey: "speedTestLiveActivity")
        downloadLiveActivity = defaults.bool(forKey: "downloadLiveActivity")
        convertToShelf = defaults.bool(forKey: "convertToShelf")
        connectionAlerts = defaults.bool(forKey: "connectionAlerts")
        agentsEnabled = defaults.bool(forKey: "agentsEnabled")
        videoDownloadsToShelf = defaults.bool(forKey: "videoDownloadsToShelf")
        videoQuality = defaults.integer(forKey: "videoQuality")
        agentAlerts = defaults.bool(forKey: "agentAlerts")
        agentsKeepAwake = defaults.bool(forKey: "agentsKeepAwake")
        agentPlans = defaults.dictionary(forKey: "agentPlans") as? [String: String] ?? [:]
        useFahrenheit = defaults.bool(forKey: "useFahrenheit")
        assistantEnabled = defaults.bool(forKey: "assistantEnabled")
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? OllamaModelCatalog.defaultModel
        // Apple's model needs nothing set up, so it's where a new install starts (Ollama otherwise).
        aiProvider = AIProvider(rawValue: defaults.string(forKey: "aiProvider") ?? "") ?? (AppleModel.isAvailable ? .apple : .local)
        cloudModels = defaults.dictionary(forKey: "cloudModels") as? [String: String] ?? [:]
        cloudBaseURLs = defaults.dictionary(forKey: "cloudBaseURLs") as? [String: String] ?? [:]
        cloudScreenQuestions = defaults.object(forKey: "cloudScreenQuestions") as? Bool ?? true
        systemNotifications = defaults.bool(forKey: "systemNotifications")
        imageIndexing = defaults.bool(forKey: "imageIndexing")
        homeCity = defaults.string(forKey: "homeCity") ?? ""
        worldClockCity = defaults.string(forKey: "worldClockCity") ?? ""
        countdownTitle = defaults.string(forKey: "countdownTitle") ?? "Launch"
        countdownDate = defaults.double(forKey: "countdownDate")
        screenQuestions = defaults.bool(forKey: "screenQuestions")
        morningBrief = defaults.bool(forKey: "morningBrief")
        briefHour = defaults.integer(forKey: "briefHour")
        dueNudges = defaults.bool(forKey: "dueNudges")
        rambleAutoDictate = defaults.bool(forKey: "rambleAutoDictate")
        meetingMode = defaults.bool(forKey: "meetingMode")
        transcribeCalls = defaults.bool(forKey: "transcribeCalls")
        soundAlerts = defaults.bool(forKey: "soundAlerts")
        progressGlance = defaults.bool(forKey: "progressGlance")
        nudgeLeadMinutes = defaults.integer(forKey: "nudgeLeadMinutes")
        calendarEnabled = defaults.bool(forKey: "calendarEnabled")
        defaultCalendarID = defaults.string(forKey: "defaultCalendarID") ?? ""
        focusSearchOnHover = defaults.bool(forKey: "focusSearchOnHover")
        meetingAlerts = defaults.bool(forKey: "meetingAlerts")
        meetingAlertMinutes = defaults.integer(forKey: "meetingAlertMinutes")
    }

    var customAccent: Color {
        get { Color(nsColor: NSColor(hex: customAccentHex) ?? .systemBlue) }
        set { customAccentHex = NSColor(newValue).hexString }
    }

    /// The accent used throughout the notch.
    func accent(for media: MediaController) -> Color {
        switch accentMode {
        case .albumArt: Color(nsColor: media.hasTrack ? media.accentColor : .white)
        case .custom: customAccent
        }
    }

    func formatTemperature(_ celsius: Double) -> String {
        "\(Int((useFahrenheit ? celsius * 9 / 5 + 32 : celsius).rounded()))°"
    }

    var openAnimation: Animation { Motion.open.animation }
    var closeAnimation: Animation { Motion.close.animation }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
