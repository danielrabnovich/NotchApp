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

    enum AnimationStyle: String, CaseIterable, Identifiable {
        case smooth, bouncy
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    private let defaults = UserDefaults.standard

    // General
    @Published var openMode: OpenMode { didSet { defaults.set(openMode.rawValue, forKey: "openMode") } }
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") } }
    @Published var showFakeNotch: Bool { didSet { defaults.set(showFakeNotch, forKey: "showFakeNotch") } }
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    @Published var hasLaunchedBefore: Bool { didSet { defaults.set(hasLaunchedBefore, forKey: "hasLaunchedBefore") } }

    // Appearance
    @Published var accentMode: AccentMode { didSet { defaults.set(accentMode.rawValue, forKey: "accentMode") } }
    @Published var customAccentHex: String { didSet { defaults.set(customAccentHex, forKey: "customAccentHex") } }
    @Published var animationStyle: AnimationStyle { didSet { defaults.set(animationStyle.rawValue, forKey: "animationStyle") } }
    @Published var showShadow: Bool { didSet { defaults.set(showShadow, forKey: "showShadow") } }

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
    @Published var keepAwakeBatteryFloor: Int { didSet { defaults.set(keepAwakeBatteryFloor, forKey: "keepAwakeBatteryFloor") } }
    @Published var reverseMouseScroll: Bool { didSet { defaults.set(reverseMouseScroll, forKey: "reverseMouseScroll") } }
    @Published var threeFingerMiddleClick: Bool { didSet { defaults.set(threeFingerMiddleClick, forKey: "threeFingerMiddleClick") } }
    @Published var cameraMirrorEnabled: Bool { didSet { defaults.set(cameraMirrorEnabled, forKey: "cameraMirrorEnabled") } }
    @Published var hotKeysEnabled: Bool { didSet { defaults.set(hotKeysEnabled, forKey: "hotKeysEnabled") } }
    @Published var hotKeyModifiers: HotKeys.Modifiers { didSet { defaults.set(hotKeyModifiers.rawValue, forKey: "hotKeyModifiers") } }

    // Stats
    @Published var statsEnabled: Bool { didSet { defaults.set(statsEnabled, forKey: "statsEnabled") } }
    @Published var useFahrenheit: Bool { didSet { defaults.set(useFahrenheit, forKey: "useFahrenheit") } }

    // Assistant (Ollama)
    @Published var assistantEnabled: Bool { didSet { defaults.set(assistantEnabled, forKey: "assistantEnabled") } }
    @Published var ollamaURL: String { didSet { defaults.set(ollamaURL, forKey: "ollamaURL") } }
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "ollamaModel") } }
    @Published var systemNotifications: Bool { didSet { defaults.set(systemNotifications, forKey: "systemNotifications") } }
    @Published var homeCity: String { didSet { defaults.set(homeCity, forKey: "homeCity") } }

    // Brief & nudges
    @Published var morningBrief: Bool { didSet { defaults.set(morningBrief, forKey: "morningBrief") } }
    @Published var briefHour: Int { didSet { defaults.set(briefHour, forKey: "briefHour") } }
    @Published var dueNudges: Bool { didSet { defaults.set(dueNudges, forKey: "dueNudges") } }
    @Published var nudgeLeadMinutes: Int { didSet { defaults.set(nudgeLeadMinutes, forKey: "nudgeLeadMinutes") } }

    // Calendar
    @Published var calendarEnabled: Bool { didSet { defaults.set(calendarEnabled, forKey: "calendarEnabled") } }
    @Published var meetingAlerts: Bool { didSet { defaults.set(meetingAlerts, forKey: "meetingAlerts") } }
    @Published var meetingAlertMinutes: Int { didSet { defaults.set(meetingAlertMinutes, forKey: "meetingAlertMinutes") } }

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
            "musicEnabled": true,
            "musicLiveActivity": true,
            "showVisualizer": true,
            "volumeHUD": true,
            "brightnessHUD": true,
            "chargingAnimation": true,
            "shelfEnabled": true,
            "screenshotCatcher": true,
            "airDropZone": true,
            "tasksEnabled": true,
            "showTaskCount": true,
            "timerEnabled": true,
            "timerLiveActivity": true,
            "timerSounds": true,
            "pomodoroAutoStart": true,
            "notesEnabled": true,
            "downloadsEnabled": true,
            "downloadAlerts": true,
            "taildropZone": TaildropService.cli != nil,
            "taildropReceive": TaildropService.cli != nil,
            "taildropToShelf": true,
            "mixerEnabled": true,
            "controlsEnabled": true,
            "updateChecks": true,
            "updateChecksApps": true,
            "updateAlerts": true,
            "keepAwakeDisplay": true,
            "keepAwakeBatteryFloor": 20,
            "reverseMouseScroll": false,
            "threeFingerMiddleClick": false,
            "cameraMirrorEnabled": true,
            "hotKeysEnabled": true,
            "hotKeyModifiers": HotKeys.Modifiers.controlOption.rawValue,
            "statsEnabled": true,
            "useFahrenheit": Locale.current.measurementSystem == .us,
            "assistantEnabled": true,
            "ollamaURL": "http://localhost:11434",
            "ollamaModel": OllamaModelCatalog.defaultModel,
            "systemNotifications": true,
            "homeCity": "",
            "morningBrief": true,
            "briefHour": 6,
            "dueNudges": true,
            "nudgeLeadMinutes": 120,
            "calendarEnabled": true,
            "meetingAlerts": true,
            "meetingAlertMinutes": 5,
        ])
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
        musicEnabled = defaults.bool(forKey: "musicEnabled")
        musicLiveActivity = defaults.bool(forKey: "musicLiveActivity")
        showVisualizer = defaults.bool(forKey: "showVisualizer")
        volumeHUD = defaults.bool(forKey: "volumeHUD")
        brightnessHUD = defaults.bool(forKey: "brightnessHUD")
        chargingAnimation = defaults.bool(forKey: "chargingAnimation")
        shelfEnabled = defaults.bool(forKey: "shelfEnabled")
        screenshotCatcher = defaults.bool(forKey: "screenshotCatcher")
        airDropZone = defaults.bool(forKey: "airDropZone")
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
        keepAwakeBatteryFloor = defaults.integer(forKey: "keepAwakeBatteryFloor")
        reverseMouseScroll = defaults.bool(forKey: "reverseMouseScroll")
        threeFingerMiddleClick = defaults.bool(forKey: "threeFingerMiddleClick")
        cameraMirrorEnabled = defaults.bool(forKey: "cameraMirrorEnabled")
        hotKeysEnabled = defaults.bool(forKey: "hotKeysEnabled")
        hotKeyModifiers = HotKeys.Modifiers(rawValue: defaults.string(forKey: "hotKeyModifiers") ?? "") ?? .controlOption
        statsEnabled = defaults.bool(forKey: "statsEnabled")
        useFahrenheit = defaults.bool(forKey: "useFahrenheit")
        assistantEnabled = defaults.bool(forKey: "assistantEnabled")
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? OllamaModelCatalog.defaultModel
        systemNotifications = defaults.bool(forKey: "systemNotifications")
        homeCity = defaults.string(forKey: "homeCity") ?? ""
        morningBrief = defaults.bool(forKey: "morningBrief")
        briefHour = defaults.integer(forKey: "briefHour")
        dueNudges = defaults.bool(forKey: "dueNudges")
        nudgeLeadMinutes = defaults.integer(forKey: "nudgeLeadMinutes")
        calendarEnabled = defaults.bool(forKey: "calendarEnabled")
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

    var openAnimation: Animation {
        animationStyle == .bouncy
            ? .spring(response: 0.42, dampingFraction: 0.68)
            : .spring(response: 0.42, dampingFraction: 0.82)
    }

    var closeAnimation: Animation { .spring(response: 0.38, dampingFraction: 0.95) }
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
