import AppKit
import Carbon.HIToolbox
import EventKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    /// Opens Settings, optionally on a specific pane.
    func show(pane: SettingsPane? = nil) {
        if let pane { SettingsRouter.shared.pane = pane }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environmentObject(AppSettings.shared)
                .environmentObject(CalendarManager.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "NotchApp Settings"
            w.titleVisibility = .hidden
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 900, height: 640))
            w.contentMinSize = NSSize(width: 800, height: 520)
            w.center()
            w.setFrameAutosaveName("NotchAppSettings")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Debug: the Settings window as a PNG, made tall enough that a whole pane fits.
    // MARK: Debug: drive the window with synthesized events (debug hooks only)

    /// Sets the content size, so event coordinates line up with snapshots.
    func debugResize(width: CGFloat, height: CGFloat) {
        window?.setContentSize(NSSize(width: width, height: height))
    }

    /// Captures the window at its current size.
    func debugSnapshot(to url: URL) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }

    /// Posts a mouse event at a point in the content view (top-left origin, points) through the
    /// app's event queue, so local monitors, tracking areas and gestures all see it.
    func debugMouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, clicks: Int = 1) {
        guard let window, let view = window.contentView else { return }
        let point = NSPoint(x: x, y: view.bounds.height - y)
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// Posts a key press to whichever window has the keyboard (Settings, or the notch).
    func debugKey(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
        guard let window = NSApp.keyWindow ?? window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    func snapshot(to url: URL) {
        guard let window, let view = window.contentView else { return }
        let old = window.frame
        window.setContentSize(NSSize(width: 900, height: 1500))
        view.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
            window.setFrame(old, display: true)
        }
    }
}

@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var pane: SettingsPane = .general
}

/// Raw values are stable identifiers (debug hooks use them); `title` is what's shown.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case addOns = "Add-ons"
    case appearance = "Appearance"
    case live = "Glances"
    case assistant = "Assistant"
    case media = "Media"
    case hud = "HUD"
    case battery = "Battery"
    case shelf = "Shelf"
    case tasks = "Tasks"
    case timer = "Timer"
    case stats = "Stats"
    case tools = "Tools"
    case agents = "Agents"
    case calendar = "Calendar"
    case controls = "Controls"
    case mouse = "Mouse"
    case updates = "Updates"
    case shortcuts = "Shortcuts"
    case permissions = "Permissions"
    case about = "About"

    var id: String { rawValue }

    enum Group: String, CaseIterable { case app = "NotchApp", features = "Features", info = "" }

    var group: Group {
        switch self {
        case .general, .addOns, .appearance, .live, .shortcuts, .permissions: .app
        case .about: .info
        default: .features
        }
    }

    var title: String {
        switch self {
        case .assistant: "Search"
        case .media: "Media & Sound"
        case .hud: "Volume & Brightness"
        case .tasks: "Tasks & Notes"
        case .controls: "Controls & Camera"
        case .mouse: "Mouse & Trackpad"
        case .shortcuts: "Keyboard Shortcuts"
        default: rawValue
        }
    }

    var summary: String {
        switch self {
        case .general: "How and where the notch opens."
        case .appearance: "Accent color and motion."
        case .live: "Keep music, a timer, stats and more beside the notch, one click away."
        case .assistant: "Files, the web and the weather, even without AI; add a model for answers and actions."
        case .media: "Now playing, the visualizer and per-app volume."
        case .hud: "Show volume and brightness changes in the notch."
        case .battery: "What the notch does when you plug in."
        case .shelf: "Drag files onto the notch to park them, then out to any app. Screenshots and downloads land here too."
        case .tasks: "Your list, reminders and a scratchpad. Drop text, links or emails on the notch to add them."
        case .timer: "Countdowns, Pomodoro and a stopwatch. Scroll the ruler or pick a preset."
        case .stats: "CPU, GPU, memory, temperatures and power. Click a card for details."
        case .tools: "Network and speed test, a cleaner, an app uninstaller and Bluetooth batteries."
        case .agents: "Claude Code, Codex, OpenCode and ZCode sessions (working, waiting for you or idle) and today's tokens."
        case .addOns: "Search, Shelf and Tasks are always there. Turn on anything else you want."
        case .calendar: "Today's events on Home, and a heads-up before meetings."
        case .controls: "Volume and brightness, the quick actions you pick, Keep Awake and a camera mirror."
        case .mouse: "Scroll direction and middle click."
        case .updates: "Homebrew and app updates, checked for you."
        case .shortcuts: "Jump straight to any tab from anywhere."
        case .permissions: "What NotchApp can see and do, and what each permission unlocks."
        case .about: "Version and app info."
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .live: "capsule.inset.filled"
        case .assistant: "sparkle.magnifyingglass"
        case .media: "music.note"
        case .hud: "speaker.wave.2.fill"
        case .battery: "battery.100.bolt"
        case .shelf: "tray.full.fill"
        case .tasks: "checklist"
        case .timer: "timer"
        case .stats: "gauge.with.dots.needle.50percent"
        case .tools: "wrench.and.screwdriver.fill"
        case .agents: "sparkles.rectangle.stack.fill"
        case .addOns: "puzzlepiece.extension.fill"
        case .calendar: "calendar"
        case .controls: "switch.2"
        case .mouse: "computermouse.fill"
        case .updates: "arrow.down.app.fill"
        case .shortcuts: "command"
        case .permissions: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .purple
        case .live: Color(red: 1, green: 0.42, blue: 0.4)
        case .assistant: .indigo
        case .media: .pink
        case .hud: .blue
        case .battery: .green
        case .shelf: .orange
        case .tasks: .teal
        case .timer: Color(red: 1, green: 0.55, blue: 0.15)
        case .stats: .cyan
        case .tools: Color(red: 0.95, green: 0.45, blue: 0.55)
        case .agents: .purple
        case .addOns: .indigo
        case .calendar: .red
        case .controls: Color(red: 0.35, green: 0.35, blue: 0.4)
        case .mouse: Color(red: 0.4, green: 0.45, blue: 0.55)
        case .updates: .blue
        case .shortcuts: Color(red: 0.25, green: 0.5, blue: 0.95)
        case .permissions: Color(red: 0.2, green: 0.65, blue: 0.45)
        case .about: .secondary
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: 236)
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.6)).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
        .frame(minWidth: 800, minHeight: 520)
    }

    private var detail: some View {
            Group {
                switch router.pane {
                case .general: GeneralPane()
                case .appearance: AppearancePane()
                case .live: LiveActivitiesPane()
                case .assistant: AssistantPane()
                case .media: MediaPane()
                case .hud: HUDPane()
                case .battery: BatteryPane()
                case .shelf: ShelfSettingsPane()
                case .tasks: TasksSettingsPane()
                case .timer: TimerPane()
                case .stats: StatsPane()
                case .tools: ToolsSettingsPane()
                case .agents: AgentsSettingsPane()
                case .addOns: AddOnsPane()
                case .calendar: CalendarPane()
                case .controls: ControlsPane()
                case .mouse: MousePane()
                case .updates: UpdatesPane()
                case .shortcuts: ShortcutsPane()
                case .permissions: PermissionsPane()
                case .about: AboutPane()
                }
            }
            // Switch instantly, like System Settings: a crossfade briefly lays the old and new
            // pages over each other, which reads as the layout shifting.
            .id(router.pane)
            .transaction { $0.animation = nil }
    }
}

// MARK: - Panes

private struct AddOnsPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .addOns) {
            Section("Tabs") {
                ToggleRow("Music", subtitle: "Now playing with controls on a Home tab, plus a live activity beside the notch.",
                          isOn: Binding(get: { s.musicEnabled }, set: { s.musicEnabled = $0; s.musicLiveActivity = $0 }))
                ToggleRow("Calendar", subtitle: "Today's events on the Home tab, with meeting alerts. Search can use your calendar either way.",
                          isOn: $s.calendarEnabled)
                ToggleRow("Timer", subtitle: "Countdowns, Pomodoro and a stopwatch. “timer 10m” in Search works either way.", isOn: $s.timerEnabled)
                ToggleRow("Mixer", subtitle: "Per-app volume.", isOn: $s.mixerEnabled)
                ToggleRow("Controls", subtitle: "Quick actions you pick: toggles, a port viewer, speed test, copy text from the screen…",
                          isOn: $s.controlsEnabled)
                ToggleRow("Stats", subtitle: "CPU, GPU, memory, temperatures and power.", isOn: $s.statsEnabled)
                ToggleRow("Tools", subtitle: "Network and speed test, a cleaner, an app uninstaller and Bluetooth batteries.",
                          isOn: $s.toolsEnabled)
                ToggleRow("Agents", subtitle: "Claude Code, Codex, OpenCode and ZCode sessions at a glance, with today's token usage.",
                          isOn: $s.agentsEnabled)
            }
            Section("Extras") {
                ToggleRow("Camera mirror", subtitle: "A quick look at yourself from the notch.", isOn: $s.cameraMirrorEnabled)
                ToggleRow("Volume & brightness", subtitle: "Shows them in the notch instead of the system overlay.",
                          isOn: Binding(get: { s.volumeHUD || s.brightnessHUD }, set: { s.volumeHUD = $0; s.brightnessHUD = $0 }))
                ToggleRow("Charging animation", subtitle: "When you plug in.", isOn: $s.chargingAnimation)
                ToggleRow("Morning brief", subtitle: "Your day at a glance on the first unlock of the morning.", isOn: $s.morningBrief)
                ToggleRow("Clipboard history", subtitle: "Recent copies on the Shelf, and “clip …” in Search. Password managers are skipped.",
                          isOn: $s.clipboardHistory)
            }
        }
    }
}

private struct GeneralPane: View {
    @EnvironmentObject private var s: AppSettings
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        SettingsPage(pane: .general) {
            Section("Opening") {
                ToggleRow("Ready to type when it opens", subtitle: "The cursor is already in the search bar when the notch opens on hover.",
                          isOn: $s.focusSearchOnHover)
                Picker(selection: $s.openMode) {
                    ForEach(AppSettings.OpenMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    RowLabel(title: "Open the notch on", subtitle: s.openMode == .hover ? "Rest the pointer on the notch to open it." : "Click the notch to open it.")
                }
                .pickerStyle(.segmented)
                if s.openMode == .hover {
                    LabeledContent {
                        HStack {
                            Slider(value: $s.hoverDelay, in: 0...1, step: 0.05)
                                .frame(maxWidth: 220)
                            Text(String(format: "%.2fs", s.hoverDelay))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    } label: {
                        RowLabel(title: "Hover delay", subtitle: "Longer means fewer accidental opens.")
                    }
                }
            }
            Section("Displays") {
                Picker("Show the notch on", selection: $s.displayMode) {
                    ForEach(AppSettings.DisplayMode.allCases) { Text($0.label).tag($0) }
                }
                ToggleRow("Fake notch on other displays", subtitle: "Draw a notch on screens that don't have one.", isOn: $s.showFakeNotch)
            }
            Section("System") {
                ToggleRow("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        LaunchAtLogin.isEnabled = v
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ToggleRow("Menu bar icon",
                          subtitle: s.showMenuBarIcon ? nil : "To get back here, right-click the notch or open NotchApp again from Finder.",
                          isOn: $s.showMenuBarIcon)
            }
        }
    }
}

private struct AppearancePane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .appearance) {
            Section("Color") {
                Picker(selection: $s.accentMode) {
                    ForEach(AppSettings.AccentMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    RowLabel(title: "Accent color", subtitle: "Used for the visualizer, HUD bars and highlights.")
                }
                if s.accentMode == .custom {
                    ColorPicker("Custom color", selection: Binding(get: { s.customAccent }, set: { s.customAccent = $0 }),
                                supportsOpacity: false)
                }
            }
            Section("Motion") {
                Picker(selection: $s.animationStyle) {
                    ForEach(AppSettings.AnimationStyle.allCases) { Text($0.label).tag($0) }
                } label: {
                    RowLabel(title: "Animation", subtitle: "How the notch springs open.")
                }
                .pickerStyle(.segmented)
                ToggleRow("Shadow when open", subtitle: "A soft shadow under the open notch.", isOn: $s.showShadow)
                ToggleRow("Haptic feedback", subtitle: "A light tap on the trackpad as the notch opens, tabs change and things snap into place.", isOn: $s.haptics)
            }
            Section {
                Picker(selection: $s.alertLevel) {
                    ForEach(AppSettings.AlertLevel.allCases) { Text($0.label).tag($0) }
                } label: {
                    RowLabel(title: "Alerts under the notch",
                             subtitle: "Important keeps only the ones that ask something of you, like a meeting about to start.")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Alerts")
            } footer: {
                FooterText("Alerts drop down under the notch without moving your Glances, wait while a full-screen app is in front, and stay while the pointer rests on them. Volume, brightness and charging have their own switches.")
            }
        }
    }
}

private struct MediaPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var mixer = AudioMixer.shared

    var body: some View {
        SettingsPage(pane: .media) {
            Section {
                ToggleRow("Music player", subtitle: "Apple Music, Spotify, Podcasts and browsers. Click the artwork to jump to the app.",
                          isOn: $s.musicEnabled)
                if s.musicEnabled {
                    ToggleRow("Live activity while playing", subtitle: "Artwork and a visualizer beside the closed notch.",
                              isOn: $s.musicLiveActivity)
                    ToggleRow("Audio visualizer", subtitle: "Moves with what's actually playing, bass to treble.", isOn: $s.showVisualizer)
                    if s.showVisualizer {
                        PermissionRow(title: "System audio recording",
                                      subtitle: "Lets the visualizer hear the music. It only listens while it's on screen; nothing is recorded or changed. Without it, the bars just animate.",
                                      state: mixer.permission == .granted ? .granted : mixer.permission == .denied ? .denied : .unknown,
                                      request: { mixer.requestPermission() },
                                      openSettings: { AudioCapturePermission.openSettings() })
                    }
                }
            } header: {
                Text("Now playing")
            }
            Section {
                ToggleRow("Sound tab", subtitle: "System volume, output device and a fader for each app.", isOn: $s.mixerEnabled)
                if s.mixerEnabled {
                    PermissionRow(title: "System audio recording",
                                  subtitle: "Needed to change an app's volume. Apps left at 100% are never touched.",
                                  state: mixer.permission == .granted ? .granted : mixer.permission == .denied ? .denied : .unknown,
                                  request: { mixer.requestPermission() },
                                  openSettings: { AudioCapturePermission.openSettings() })
                }
            } header: {
                Text("Sound mixer")
            }
        }
    }
}

private struct HUDPane: View {
    @EnvironmentObject private var s: AppSettings
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPage(pane: .hud) {
            Section {
                ToggleRow("Volume", isOn: $s.volumeHUD)
                ToggleRow("Brightness", isOn: $s.brightnessHUD)
            } header: {
                Text("Show in the notch")
            } footer: {
                FooterText("Hold Shift + Option while pressing a volume or brightness key for finer steps.")
            }
            Section("Permission") {
                PermissionRow(title: "Accessibility",
                              subtitle: trusted ? nil : "Without it the notch HUD still appears, but macOS shows its own overlay too.",
                              state: trusted ? .granted : .unknown) {
                    HUDController.shared.requestAccessibility()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }
}

private struct BatteryPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .battery) {
            Section {
                ToggleRow("Charging animation", subtitle: "Show the battery level beside the notch when you plug in.",
                          isOn: $s.chargingAnimation)
            }
        }
    }
}

private struct ShelfSettingsPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .shelf) {
            Section {
                if s.shelfEnabled {
                    ToggleRow("Catch new screenshots", subtitle: "New screenshots land on the shelf automatically.", isOn: $s.screenshotCatcher)
                    if s.screenshotCatcher {
                        ToggleRow("Throw screenshots away when done",
                                  subtitle: "15 minutes after you take one, or a minute after you paste it, it moves to the Trash. Pin a screenshot to keep it.",
                                  isOn: $s.screenshotCleanup)
                    }
                    ToggleRow("AirDrop drop zone", isOn: $s.airDropZone)
                    ToggleRow("Copy what you add", subtitle: "The latest thing added to the shelf is also copied, so you can paste it anywhere.", isOn: $s.copyShelfAdds)
                }
            }
            if s.shelfEnabled {
                Section("Quick drops") {
                    ToggleRow("Stack under the notch",
                              subtitle: "Dropped files wait under the notch: drag them straight into another app without opening it. Once dropped, they leave the shelf (hold ⌥ to keep them).",
                              isOn: $s.shelfStack)
                    Picker(selection: $s.shelfExpiry) {
                        ForEach(AppSettings.ShelfExpiry.allCases) { Text($0.label).tag($0) }
                    } label: {
                        RowLabel(title: "Clear unpinned files",
                                 subtitle: "Pin a file (right-click it on the shelf) to keep it. Only the shelf entry goes; the file itself isn't touched.")
                    }
                }
            }
            if s.shelfEnabled {
                Section {
                    if TaildropService.cli == nil {
                        LabeledContent {
                            Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download/mac")!)
                        } label: {
                            RowLabel(title: "Tailscale isn't installed", subtitle: "Taildrop sends files between your own devices over Tailscale.")
                        }
                    } else {
                        ToggleRow("Taildrop zone", subtitle: "Drop files on it, or click it, to send them to one of your devices.", isOn: $s.taildropZone)
                        ToggleRow("Receive Taildrop files", subtitle: "Files sent to this Mac go to Downloads, with a heads-up in the notch.",
                                  isOn: $s.taildropReceive)
                        if s.taildropReceive {
                            ToggleRow("Put received files on the shelf", isOn: $s.taildropToShelf)
                        }
                    }
                } header: {
                    Text("Taildrop")
                }
                Section {
                    ToggleRow("Clipboard history", subtitle: "Text, links, images and files you copy, next to the shelf. Click one to copy it again.",
                              isOn: $s.clipboardHistory)

                } header: {
                    Text("Clipboard")
                } footer: {
                    FooterText("Kept on this Mac only. Copies from password managers, or marked private by the app they came from, are never saved.")
                }
                Section {
                    if VideoDownloader.isAvailable {
                        LabeledContent {
                            Button("Update yt-dlp") { VideoDownloader.shared.upgrade() }
                        } label: {
                            RowLabel(title: "yt-dlp found", subtitle: (VideoDownloader.binary?.path ?? "") + (VideoDownloader.ffmpeg == nil ? " · install ffmpeg for best quality" : " · with ffmpeg"))
                        }
                        Picker(selection: $s.videoQuality) {
                            Text("Best available").tag(0)
                            Text("4K").tag(2160)
                            Text("1440p").tag(1440)
                            Text("1080p").tag(1080)
                            Text("720p").tag(720)
                            Text("480p").tag(480)
                        } label: {
                            RowLabel(title: "Default quality", subtitle: "For drops and quick downloads; Search and the Save Video menu list every size. Above 1080p is usually AV1 or VP9 (IINA plays both).")
                        }
                        ToggleRow("Put finished videos on the shelf", isOn: $s.videoDownloadsToShelf)
                        ToggleRow("Show progress beside the notch", subtitle: "A ring and percentage while a download runs.",
                                  isOn: $s.downloadLiveActivity)
                    } else {
                        RowLabel(title: "yt-dlp isn't installed", subtitle: "Run “brew install yt-dlp ffmpeg” in Terminal, then reopen Settings.")
                    }
                } header: {
                    Text("Video downloads")
                } footer: {
                    FooterText("Paste a link into Search, drag one onto the notch (hold ⌥ for audio only), or right-click a copied link on the Clipboard shelf. Files go to Downloads.")
                }
                Section {
                    ToggleRow("Put converted files on the shelf", subtitle: "Conversions are saved next to the original either way.",
                              isOn: $s.convertToShelf)
                } header: {
                    Text("Convert")
                } footer: {
                    FooterText(VideoDownloader.ffmpeg == nil
                         ? "Images convert with macOS's own tools. Install ffmpeg (brew install ffmpeg) to convert video and audio."
                         : "Drop files on the Convert bin, or right-click a shelf item. Video and audio use ffmpeg from Homebrew.")
                }
                Section("Downloads") {
                    ToggleRow("Recent downloads", subtitle: "Your latest finished downloads, next to the shelf.", isOn: $s.downloadsEnabled)
                    if s.downloadsEnabled {
                        ToggleRow("Alert when a download finishes", isOn: $s.downloadAlerts)
                    }
                }
            }
        }
    }
}

private struct TasksSettingsPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .tasks) {
            Section {
                if s.tasksEnabled {
                    ToggleRow("Open count beside the notch", isOn: $s.showTaskCount)
                    ToggleRow("Notes scratchpad", subtitle: "A free-form note next to your tasks, saved automatically.", isOn: $s.notesEnabled)
                }
            }
            if s.tasksEnabled {
                Section {
                    ToggleRow("Morning brief", subtitle: "Drops down the first time you unlock your Mac each day.", isOn: $s.morningBrief)
                    if s.morningBrief {
                        Picker("Show after", selection: $s.briefHour) {
                            ForEach(Array(4...12), id: \.self) { h in Text(hourLabel(h)).tag(h) }
                        }
                    }
                    ToggleRow("Nudge before tasks are due", subtitle: "Type due dates naturally: “send deck by Friday 3pm”.", isOn: $s.dueNudges)
                    if s.dueNudges {
                        Picker("Nudge", selection: $s.nudgeLeadMinutes) {
                            Text("30 minutes before").tag(30)
                            Text("1 hour before").tag(60)
                            Text("2 hours before").tag(120)
                            Text("4 hours before").tag(240)
                            Text("1 day before").tag(1440)
                        }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    HStack {
                        Spacer()
                        Button("Show Brief Now") { BriefingService.shared.maybeShowBrief(force: true) }
                            .disabled(!s.morningBrief)
                    }
                }
            }
        }
    }
}

private func hourLabel(_ h: Int) -> String {
    let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
    return date.formatted(date: .omitted, time: .shortened)
}

/// The optional MobileCLIP download: describe a picture in your own words.
private struct VisualSearchRow: View {
    @ObservedObject private var visual = VisualSearch.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Understand descriptions")
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .downloading(let fraction) = visual.state {
                    ProgressView(value: fraction).controlSize(.small)
                }
            }
            Spacer()
            switch visual.state {
            case .notInstalled, .failed:
                Button("Download") { visual.install() }
            case .downloading:
                Button("Cancel") { visual.cancel() }
            case .preparing:
                ProgressView().controlSize(.small)
            case .ready:
                Button("Remove") { visual.remove() }
            }
        }
    }

    private var subtitle: String {
        switch visual.state {
        case .notInstalled:
            return "Describe a picture in your own words: “lighthouse at dusk”, “whiteboard with a diagram”. Downloads Apple's MobileCLIP (110 MB); it runs on this Mac."
        case .downloading(let fraction):
            return "Downloading MobileCLIP… \(Int(fraction * 100))%"
        case .preparing:
            return "Getting MobileCLIP ready…"
        case .ready:
            return "Pictures are matched against what you describe, on this Mac."
        case .failed(let message):
            return "Download failed: \(message)"
        }
    }
}

/// A cloud provider's key (kept in the Keychain), address and model. Saving or checking the key
/// lists the models it can use, which is also the proof that it works; pick one from the list.
private struct CloudProviderSettings: View {
    let provider: AIProvider
    @EnvironmentObject private var s: AppSettings
    @State private var key = ""
    @State private var hasKey = false
    /// Typing a new key over a saved one.
    @State private var replacing = false
    @State private var models: [CloudLLM.ModelInfo] = []
    @State private var checking = false
    @State private var result: (ok: Bool, message: String)?
    @State private var filter = ""
    /// A long model list, opened to pick from.
    @State private var browsing = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        Group {
            LabeledContent {
                if hasKey && !replacing { savedKey } else { keyField }
            } label: {
                RowLabel(title: "API key", subtitle: keySubtitle)
            }
            if provider.editableServer {
                TextField(text: Binding(get: { s.cloudBaseURL(for: provider) },
                                        set: { s.cloudBaseURLs[provider.rawValue] = $0 }),
                          prompt: Text(provider.defaultBaseURL)) {
                    RowLabel(title: "Server", subtitle: serverSubtitle)
                }
            }
            status
            if !models.isEmpty {
                modelPicker
            } else if result?.ok != true {
                TextField(text: modelBinding, prompt: Text(provider.suggestedModel.isEmpty ? "Model name" : provider.suggestedModel)) {
                    RowLabel(title: "Model", subtitle: "Or check the key to pick from the models it can use.")
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: provider) { _, _ in load() }
    }

    /// A saved key: that it's there (and which one, by its last characters), not an empty field.
    private var savedKey: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill").font(.system(size: 10.5))
                Text("Saved")
                    .fontWeight(.medium)
                if let tail = APIKeys.get(provider).map({ String($0.suffix(4)) }), !tail.isEmpty {
                    Text("••••\(tail)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.green.opacity(0.13)))
            .help("Kept in your Mac's Keychain")
            Button("Replace…") {
                replacing = true
                keyFocused = true
            }
            Button(role: .destructive) {
                APIKeys.set(nil, for: provider)
                hasKey = false
                models = []
                result = nil
                AssistantStore.shared.refreshStatus()
            } label: { Image(systemName: "trash") }
            .help("Remove the key")
        }
    }

    private var keyField: some View {
        HStack {
            SecureField("", text: $key, prompt: Text(provider.keyPlaceholder))
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .frame(minWidth: 180)
                .onSubmit(save)
            Button("Save", action: save)
                .disabled(checking || (key.isEmpty && provider.keyRequired))
            if replacing {
                Button("Cancel") { replacing = false; key = "" }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if checking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(provider.shortName)…").foregroundStyle(.secondary)
            }
            .font(.caption)
        } else if let result {
            HStack(spacing: 6) {
                Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.ok ? .green : .orange)
                Spacer()
                Button("Check again", action: check)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    /// The model: a menu when the list is short; when it's long (OpenRouter's hundreds), the chosen
    /// one with a filterable list to change it, laid out in the page rather than scrolling inside it.
    @ViewBuilder private var modelPicker: some View {
        let chosen = s.cloudModel(for: provider)
        if models.count <= 20 {
            Picker(selection: Binding(get: { chosen }, set: { s.cloudModels[provider.rawValue] = $0; AssistantStore.shared.refreshStatus() })) {
                if !models.contains(where: { $0.id == chosen }) { Text(chosen.isEmpty ? "Choose…" : chosen).tag(chosen) }
                ForEach(models) { model in Text(model.name ?? model.id).tag(model.id) }
            } label: {
                RowLabel(title: "Model", subtitle: models.first { $0.id == chosen }.flatMap { $0.name == nil ? nil : $0.id })
            }
        } else {
            LabeledContent {
                Button(browsing ? "Done" : "Change…") { browsing.toggle(); filter = "" }
            } label: {
                RowLabel(title: "Model", subtitle: models.first { $0.id == chosen }.map { ($0.name ?? $0.id) + ($0.name == nil ? "" : " · \($0.id)") } ?? chosen)
            }
            if browsing { modelBrowser(chosen: chosen) }
        }
    }

    private func modelBrowser(chosen: String) -> some View {
        let matches = filter.isEmpty ? models : models.filter {
            $0.id.localizedCaseInsensitiveContains(filter) || ($0.name?.localizedCaseInsensitiveContains(filter) ?? false)
        }
        let shown = matches.prefix(8)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("", text: $filter, prompt: Text("Filter \(models.count) models"))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            VStack(spacing: 1) {
                ForEach(shown) { model in
                    ModelChoiceRow(model: model, chosen: model.id == chosen) {
                        s.cloudModels[provider.rawValue] = model.id
                        AssistantStore.shared.refreshStatus()
                        browsing = false
                    }
                }
            }
            if matches.count > shown.count {
                Text("\(matches.count - shown.count) more · type to narrow it down").font(.caption).foregroundStyle(.secondary)
            } else if matches.isEmpty {
                Text("No models match “\(filter)”").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var keySubtitle: String? {
        guard let url = provider.keyURL else { return "Kept in your Mac's Keychain." }
        return "Get one at \(url.host() ?? url.absoluteString). Kept in your Mac's Keychain."
    }

    private var serverSubtitle: String? {
        switch provider {
        case .custom: "LM Studio, vLLM, Together, Mistral, xAI… anything that speaks the OpenAI chat API."
        case .customAnthropic: "Kimi, MiniMax, Qwen… anything that speaks Anthropic's Messages API."
        case .zai: "For the GLM Coding Plan, keep this address and use that plan's key."
        default: nil
        }
    }

    private var modelBinding: Binding<String> {
        Binding(get: { s.cloudModel(for: provider) }, set: { s.cloudModels[provider.rawValue] = $0; AssistantStore.shared.refreshStatus() })
    }

    private func load() {
        key = ""
        filter = ""
        replacing = false
        browsing = false
        hasKey = APIKeys.get(provider) != nil
        models = []
        result = nil
        if hasKey || !provider.keyRequired { check() }
    }

    private func save() {
        if !key.isEmpty {
            APIKeys.set(key, for: provider)
            key = ""
            hasKey = true
            replacing = false
        }
        check()
    }

    private func check() {
        guard let url = URL(string: s.cloudBaseURL(for: provider)) else { return }
        let config = CloudLLM.Config(provider: provider, key: APIKeys.get(provider), model: s.cloudModel(for: provider), baseURL: url)
        checking = true
        result = nil
        Task {
            do {
                let list = try await CloudLLM.models(config)
                models = list
                // Nothing chosen yet (or a name this key can't use): the first one listed.
                let chosen = s.cloudModel(for: provider)
                if chosen.isEmpty || !list.contains(where: { $0.id == chosen }), let first = list.first {
                    s.cloudModels[provider.rawValue] = provider.suggestedModel.isEmpty || !list.contains(where: { $0.id == provider.suggestedModel })
                        ? first.id : provider.suggestedModel
                }
                result = (true, "Connected to \(provider.shortName) · \(list.count) model\(list.count == 1 ? "" : "s") available")
            } catch {
                models = []
                result = (false, error.localizedDescription)
            }
            checking = false
            AssistantStore.shared.refreshStatus()
        }
    }
}

/// One model in the long list: its name and id, ticked when chosen, lit on hover.
private struct ModelChoiceRow: View {
    let model: CloudLLM.ModelInfo
    let chosen: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name ?? model.id).font(.system(size: 12.5, weight: chosen ? .semibold : .regular))
                    if model.name != nil {
                        Text(model.id).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if chosen { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(chosen ? Color.accentColor.opacity(0.16) : hovering ? Color.primary.opacity(0.06) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Settings → Search → AI Commands: saved prompts for selected text, each replacing the selection
/// or showing its result. Used from "ai …" in the bar and from Ask About This with a selection.
private struct AICommandsEditor: View {
    @ObservedObject private var store = AICommandStore.shared
    @State private var expanded: UUID?

    var body: some View {
        Section {
            ForEach($store.commands) { $command in
                VStack(alignment: .leading, spacing: 0) {
                    AICommandRow(command: command, expanded: expanded == command.id) {
                        withAnimation(.snappy(duration: 0.22)) { expanded = expanded == command.id ? nil : command.id }
                    }
                    if expanded == command.id {
                        AICommandEditor(command: $command) {
                            withAnimation(.snappy(duration: 0.22)) { store.remove(command.id) }
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .onMove { store.commands.move(fromOffsets: $0, toOffset: $1) }
            HStack {
                Button {
                    store.add()
                    withAnimation(.snappy(duration: 0.22)) { expanded = store.commands.last?.id }
                } label: { Label("Add Command", systemImage: "plus") }
                Spacer()
                Button("Restore Defaults") { store.resetToDefaults() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI Commands")
        } footer: {
            FooterText("Select text anywhere, then type “ai” in the bar or press Ask About This (\(HotKeys.combo(for: .askScreen)?.display ?? "its shortcut")); the first four show as buttons. Replace commands put the result back where the text was (⌘Z undoes it). Drag to reorder.")
        }
    }
}

/// A command, folded: its icon, name, what it asks for, and what happens to the result. The whole
/// row opens it.
private struct AICommandRow: View {
    let command: AICommand
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: command.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(command.output == .replace ? Color.indigo.gradient : Color.teal.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.name)
                    Text(command.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(command.output == .replace ? "Replaces" : "Shows")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .opacity(hovering && !expanded ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A command, open: its name and icon, where the result goes, and the instruction.
private struct AICommandEditor: View {
    @Binding var command: AICommand
    let delete: () -> Void

    /// Symbols that suit writing commands.
    private static let icons = ["sparkles", "checkmark.seal", "face.smiling", "briefcase", "text.alignleft", "lightbulb",
                                "character.bubble", "arrowshape.turn.up.left", "arrow.down.right.and.arrow.up.left",
                                "list.bullet", "quote.bubble", "envelope", "pencil", "wand.and.stars", "doc.text.magnifyingglass",
                                "number", "curlybraces", "megaphone", "heart", "graduationcap"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(Self.icons, id: \.self) { icon in
                        Button { command.icon = icon } label: { Label(icon, systemImage: icon) }
                    }
                } label: {
                    Image(systemName: command.icon)
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Icon")
                TextField("", text: $command.name, prompt: Text("Name"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("Result", selection: $command.output) {
                Text("Replace the selection").tag(AICommand.Output.replace)
                Text("Show in the notch").tag(AICommand.Output.show)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                Text("Instruction").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $command.prompt, prompt: Text("What to do with the selected text"), axis: .vertical)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
            }
            HStack {
                Spacer()
                Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct AssistantPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var assistant = AssistantStore.shared
    @ObservedObject private var folders = FolderAccess.shared
    @ObservedObject private var images = ImageIndex.shared
    @State private var customModel = ""

    private var folderState: PermissionRow.State {
        if folders.access.isEmpty { return .unknown }
        return folders.missing.isEmpty ? .granted : .denied
    }

    private var folderSubtitle: String {
        if folders.missing.isEmpty {
            return folders.access.isEmpty ? "So file search can see the files you keep there." : "File search can see these folders."
        }
        return "Can't see \(folders.missing.map(\.name).joined(separator: ", ")). Turn it on under Files & Folders."
    }

    /// What the picture index is up to, under its toggle.
    private var imageSubtitle: String {
        let what = "Find photos and screenshots by what's in them, or the text they contain. Your Mac's built-in Vision looks at each one, on this Mac."
        guard s.imageIndexing else { return what }
        if images.isIndexing { return "Looking at your pictures in the background. Search finds the ones done so far." }
        return images.indexed > 0 ? "\(what) \(images.indexed.formatted()) pictures so far." : what
    }

    var body: some View {
        SettingsPage(pane: .assistant) {
            Section {
                ToggleRow("Notify when a search finishes", subtitle: "A macOS notification if the notch is closed.",
                          isOn: $s.systemNotifications)
            } footer: {
                FooterText(s.aiProvider == .local
                           ? "With a local model through Ollama, search understands what you mean, picks the right file and writes answers. Everything stays on your Mac except web searches."
                           : "Search, briefs, nudges and screen questions use \(s.aiProvider.title) with your key. What you search for (and, if allowed below, the window you ask about) is sent to \(s.aiProvider.shortName).")
            }
            Section {
                Picker(selection: $s.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                } label: {
                    RowLabel(title: "Model", subtitle: "Local stays private and free; a cloud model with your own key is smarter and faster.")
                }
                if s.aiProvider != .local {
                    CloudProviderSettings(provider: s.aiProvider)
                }
            } header: {
                Text("Intelligence")
            }
            AICommandsEditor()
            Section("Files & folders") {
                PermissionRow(title: "Desktop, Documents, Downloads & cloud folders",
                              subtitle: folderSubtitle,
                              state: folderState,
                              request: { Task { await folders.recheck() } },
                              openSettings: { FolderAccess.openPrivacySettings() })
                ToggleRow("Search inside pictures", subtitle: imageSubtitle, isOn: $s.imageIndexing)
                ToggleRow("Search the text in screenshots", subtitle: "Screenshots are read on this Mac (newest first) so Search finds them by what they say.",
                          isOn: $s.screenshotSearch)
                if s.imageIndexing, images.isIndexing {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: images.fraction)
                        Text("\(images.passDone.formatted()) of \(images.passTotal.formatted()) pictures\(images.timeLeft.map { " · \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if s.imageIndexing { VisualSearchRow() }
            }
            if s.aiProvider == .local, assistant.pullingModel != nil || assistant.pullError != nil || assistant.justPulled != nil {
                Section { DownloadActivity() }
            }
            if s.aiProvider == .local {
            Section("Ollama") {
                LabeledContent("Status") {
                    if let pulling = assistant.pullingModel {
                        Label("Downloading \(OllamaModelCatalog.displayName(pulling))…", systemImage: "arrow.down.circle")
                            .foregroundStyle(.blue)
                    } else {
                        statusLabel
                    }
                }
                Picker("Model", selection: Binding(get: { s.ollamaModel }, set: { assistant.use($0) })) {
                    ForEach(pickerModels, id: \.self) { name in
                        Text(assistant.isInstalled(name) ? OllamaModelCatalog.displayName(name)
                                                         : "\(OllamaModelCatalog.displayName(name)) (not downloaded)").tag(name)
                    }
                }
                TextField("Server", text: $s.ollamaURL)
            }
            Section {
                ForEach(OllamaModelCatalog.recommended) { entry in
                    ModelRow(name: entry.name, title: entry.title, detail: entry.blurb, size: entry.size)
                }
                ForEach(otherInstalled) { model in
                    ModelRow(name: model.name, title: model.name, detail: "Installed",
                             size: ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Other model", text: $customModel, prompt: Text("Any name from ollama.com/library, e.g. deepseek-r1:8b"))
                            .onSubmit(downloadCustom)
                        Button("Download", action: downloadCustom)
                            .disabled(!customIsValid || assistant.pullingModel != nil)
                    }
                    if !cleanedCustom.isEmpty && !customIsValid {
                        Text("Model names look like qwen3.5:9b (letters, numbers, . - _ and one :tag).")
                            .font(.caption).foregroundStyle(.orange)
                    } else if assistant.isInstalled(cleanedCustom) && !cleanedCustom.isEmpty {
                        Text("\(cleanedCustom) is already downloaded.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Download a model")
            } footer: {
                HStack {
                    Text(diskUsage)
                    Spacer()
                    Link("Browse the Ollama library", destination: URL(string: "https://ollama.com/library")!)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            }
            Section {
                ToggleRow("Answer questions about your screen",
                          subtitle: "“What’s the answer to this question” (or Ask about this) looks at the window in front. It’s never saved.",
                          isOn: $s.screenQuestions)
                if s.screenQuestions, s.aiProvider != .local {
                    ToggleRow("Use \(s.aiProvider.shortName) for screen questions",
                              subtitle: s.cloudScreenQuestions
                                ? "The window you ask about (a picture and its text) is sent to \(s.aiProvider.shortName) with the question."
                                : "Screen questions stay on this Mac and use the local Ollama model.",
                              isOn: $s.cloudScreenQuestions)
                }
                if s.screenQuestions && !ScreenQuestion.hasPermission {
                    LabeledContent {
                        Button("Open Settings") { ScreenQuestion.openPrivacySettings() }
                    } label: {
                        RowLabel(title: "Screen Recording is off", subtitle: "Needed to see your screen.")
                    }
                }
            } header: {
                Text("Your screen")
            }
            Section("Weather") {
                TextField(text: $s.homeCity, prompt: Text("e.g. Chapel Hill, NC")) {
                    RowLabel(title: "Home city", subtitle: "Used when you don't name a place.")
                }
            }
        }
        .task { assistant.refreshStatus() }
        .onChange(of: s.ollamaURL) { _, _ in assistant.refreshStatus() }
        .onChange(of: s.aiProvider) { _, _ in assistant.refreshStatus() }
        .onChange(of: assistant.justPulled) { _, done in
            // Keep what was typed until it downloads, so a typo can be fixed and retried.
            if let done, done == cleanedCustom { customModel = "" }
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch assistant.status {
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notRunning: Button("Start Ollama") { assistant.startServer() }
        case .modelMissing:
            Text(assistant.installed.isEmpty ? "No model downloaded" : "Selected model isn't downloaded")
                .foregroundStyle(.orange)
        case .unknown: ProgressView().controlSize(.small)
        case .needsKey: Text("Add an API key above").foregroundStyle(.orange)
        }
    }

    private var cleanedCustom: String { OllamaClient.cleanModelName(customModel) }
    private var customIsValid: Bool { OllamaClient.isPlausibleModelName(cleanedCustom) }

    /// Installed models plus the selected one, so the picker always shows the current choice.
    private var pickerModels: [String] {
        var names = assistant.installed.map(\.name)
        if !names.contains(where: { OllamaClient.matches(installed: $0, wanted: s.ollamaModel) }) { names.append(s.ollamaModel) }
        return names.sorted()
    }

    private var otherInstalled: [OllamaClient.InstalledModel] {
        assistant.installed.filter { model in
            !OllamaModelCatalog.recommended.contains { OllamaClient.matches(installed: model.name, wanted: $0.name) }
        }
    }

    private var diskUsage: String {
        let total = assistant.installed.reduce(0) { $0 + $1.size }
        return total == 0 ? "No models downloaded" : "Models use \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    private func downloadCustom() {
        guard customIsValid, assistant.pullingModel == nil else { return }
        assistant.pullModel(cleanedCustom)
    }
}

/// The current download (or its result), shown at the top of the pane so it's never off-screen.
private struct DownloadActivity: View {
    @ObservedObject private var assistant = AssistantStore.shared

    var body: some View {
        if let name = assistant.pullingModel, let p = assistant.pull {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("\(p.phase == .lookingUp ? "Finding" : "Downloading") \(OllamaModelCatalog.displayName(name))").fontWeight(.medium)
                    Spacer()
                    Button("Cancel") { assistant.cancelPull() }
                }
                if p.phase == .lookingUp {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    // Full once the bytes are in, while Ollama verifies and writes the model.
                    ProgressView(value: p.phase == .downloading ? (p.fraction ?? 0) : 1)
                }
                Text(detail(name, p))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } else if let error = assistant.pullError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(assistant.failedPull.map { "Couldn't download \($0)" } ?? "Download failed").fontWeight(.medium)
                    Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let failed = assistant.failedPull {
                    Button("Try Again") { assistant.pullModel(failed) }
                }
                Button("Dismiss") { assistant.dismissPullError() }
            }
        } else if let done = assistant.justPulled {
            Label("\(OllamaModelCatalog.displayName(done)) downloaded and ready to use", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func detail(_ name: String, _ p: OllamaClient.PullProgress) -> String {
        switch p.phase {
        case .lookingUp: return "Looking up \(name) in the Ollama library…"
        case .verifying: return "Verifying the download…"
        case .finishing: return "Finishing up…"
        case .downloading:
            let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
            var parts = ["\(size(p.completed)) of \(size(p.total))", "\(Int(((p.fraction ?? 0) * 100).rounded()))%"]
            if assistant.pullSpeed > 1 {
                parts.append("\(size(Int64(assistant.pullSpeed)))/s")
                let remaining = Double(p.total - p.completed) / assistant.pullSpeed
                let f = DateComponentsFormatter()
                f.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
                f.unitsStyle = .abbreviated
                f.maximumUnitCount = 2
                if let eta = f.string(from: remaining) { parts.append("\(eta) left") }
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// One downloadable model: download with progress, switch to it, or delete it.
private struct ModelRow: View {
    let name: String
    let title: String
    let detail: String
    let size: String
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var assistant = AssistantStore.shared
    @State private var confirmDelete = false

    var body: some View {
        let installed = assistant.isInstalled(name)
        let selected = OllamaClient.matches(installed: name, wanted: s.ollamaModel) || name == s.ollamaModel
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if name == OllamaModelCatalog.defaultModel {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.blue.opacity(0.18)))
                            .foregroundStyle(.blue)
                    }
                }
                Text("\(detail) · \(size)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if assistant.pullingModel == name {
                ProgressView(value: assistant.pullProgress ?? 0).frame(width: 90)
                Text("\(Int((assistant.pullProgress ?? 0) * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Button { assistant.cancelPull() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Cancel download")
            } else if installed {
                if selected {
                    Label("In use", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
                } else {
                    Button("Use") { assistant.use(name) }
                }
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete \(title)")
            } else {
                Button("Download") { assistant.pullModel(name) }
                    .disabled(assistant.pullingModel != nil)
            }
        }
        .confirmationDialog("Delete \(title)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { assistant.deleteModel(name) }
        } message: {
            Text("This frees \(size) of disk space. You can download it again later.")
        }
    }
}

private struct TimerPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .timer) {
            Section {
                if s.timerEnabled {
                    ToggleRow("Countdown beside the notch", subtitle: "A progress ring and the time left while the notch is closed.",
                              isOn: $s.timerLiveActivity)
                    ToggleRow("Play sounds", subtitle: "A chime when a timer or Pomodoro phase ends.", isOn: $s.timerSounds)
                }
            }
            if s.timerEnabled {
                Section("Pomodoro") {
                    ToggleRow("Start the next phase automatically", subtitle: "Go straight from focus to break and back.",
                              isOn: $s.pomodoroAutoStart)
                }
            }
        }
    }
}

private struct StatsPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var live = LiveActivities.shared

    var body: some View {
        SettingsPage(pane: .stats) {
            Section {
                Picker("Temperature", selection: $s.useFahrenheit) {
                    Text("Celsius").tag(false)
                    Text("Fahrenheit").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Section {
                ForEach([LiveItem.cpu, .memory, .gpu, .temperature, .power], id: \.self) { item in
                    Toggle(isOn: Binding(get: { live.slot(for: item) != nil },
                                         set: { $0 ? live.pin(item) : live.unpin(item) })) {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(item.tint.gradient))
                            RowLabel(title: item.title, subtitle: item.detail)
                        }
                    }
                    .disabled(live.slot(for: item) == nil && live.isFull(.left) && live.isFull(.right))
                }
            } header: {
                Text("Beside the notch")
            } footer: {
                HStack(spacing: 4) {
                    FooterText("Readings stay in view while the notch is closed; click one for its card.")
                    Button("Arrange Glances…") { SettingsRouter.shared.pane = .live }
                        .buttonStyle(.link)
                        .font(.caption)
                        .fixedSize()
                }
            }
        }
    }
}

private struct CalendarPane: View {
    @EnvironmentObject private var s: AppSettings
    @EnvironmentObject private var calendar: CalendarManager

    var body: some View {
        SettingsPage(pane: .calendar) {
            Section {
                if s.calendarEnabled {
                    ToggleRow("Meeting alerts", subtitle: "A heads-up from the notch before each meeting.", isOn: $s.meetingAlerts)
                    if s.meetingAlerts {
                        Stepper(value: $s.meetingAlertMinutes, in: 1...30) {
                            LabeledContent("Alert before") {
                                Text("\(s.meetingAlertMinutes) min").monospacedDigit()
                            }
                        }
                    }
                }
            }
            Section {
                Picker("Add new events to", selection: $s.defaultCalendarID) {
                    Text("System default").tag("")
                    ForEach(calendar.hasAccess ? calendar.writableCalendars : [], id: \.calendarIdentifier) { cal in
                        Text(cal.title + (cal.source.map { " · \($0.title)" } ?? "")).tag(cal.calendarIdentifier)
                    }
                }
            } header: {
                Text("Search bar")
            } footer: {
                FooterText("Type things like “lunch with Sam friday at 1”, “push my 3pm to 4” or “am I free tomorrow afternoon”. Google, Outlook and other calendars work once they're added in System Settings → Internet Accounts.")
            }
            Section("Permission") {
                PermissionRow(title: "Calendar", state: calendar.hasAccess ? .granted : .unknown) { calendar.requestAccess() }
            }
        }
    }
}

private struct ToolsSettingsPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var speed = SpeedTest.shared

    var body: some View {
        SettingsPage(pane: .tools) {
            Section {
            }
            Section("Network") {
                ToggleRow("Connection alerts", subtitle: "When you go offline or come back, a VPN connects or drops, or your public IP changes.",
                          isOn: $s.connectionAlerts)
                ToggleRow("Dev server alerts", subtitle: "When a local server starts (npm run dev, rails s…), with a button to open it.",
                          isOn: $s.devServerAlerts)
                ToggleRow("Show speed tests beside the notch", subtitle: "The live speed while a test runs.", isOn: $s.speedTestLiveActivity)
                LabeledContent {
                    Button("Clear History") { speed.clearHistory() }.disabled(speed.history.isEmpty)
                } label: {
                    RowLabel(title: "Speed test history", subtitle: speed.history.isEmpty ? "No tests yet."
                             : "\(speed.history.count) result\(speed.history.count == 1 ? "" : "s"). Last: ↓ \(formatMbps(speed.history[0].download)) ↑ \(formatMbps(speed.history[0].upload)) Mbps.")
                }
            }
            Section {
                ToggleRow("Low disk space alert", subtitle: "A heads-up once a day when less than 10 GB is free.", isOn: $s.lowDiskAlerts)
            } header: {
                Text("Cleaner")
            } footer: {
                FooterText("Everything the cleaner removes goes to the Trash, so you can put it back. To include the Trash's own size, give NotchApp Full Disk Access in Privacy & Security.")
            }
            Section("Devices") {
                ToggleRow("Low battery alerts", subtitle: "When AirPods, a mouse or a keyboard drops to 20%.", isOn: $s.deviceBatteryAlerts)
                ToggleRow("Microphone and camera alerts", subtitle: "A heads-up when an app starts using them, and which app has the microphone.",
                          isOn: $s.privacyAlerts)
            }
        }
    }
}

private struct AgentsSettingsPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var agents = AgentMonitor.shared

    var body: some View {
        SettingsPage(pane: .agents) {
            Section {
                if s.agentsEnabled {
                    ToggleRow("Alerts", subtitle: "A heads-up when an agent finishes, or stops to ask you something.", isOn: $s.agentAlerts)
                    ToggleRow("Keep the Mac awake while agents work", subtitle: "Turns on Keep Awake while any session is working, and off two minutes after the last one stops.",
                              isOn: $s.agentsKeepAwake)
                }
            } footer: {
                FooterText("Pin “Agents” in Glances to keep a working count beside the notch. Click a session to jump to its terminal.")
            }
            Section {
                // One form row holding all four: as separate rows, the form drew the last one
                // (with its menu) outside the section's card.
                VStack(spacing: 0) {
                    ForEach(Array(AgentMonitor.Tool.allCases.enumerated()), id: \.element) { i, tool in
                        if i > 0 { Divider().padding(.vertical, 8) }
                        AgentPlanRow(tool: tool, installed: agents.installed.contains(tool), note: planNote(tool))
                    }
                }
                .padding(.vertical, 2)
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plans")
                    // Here rather than in a footer: a long footer pulls the last picker row out of the card.
                    Text("Read from each agent's own settings where they record one (Claude Code, Codex). ZCode only says a coding plan is connected, so pick your tier. Usage compares the API value of what you used with what the plan costs.")
                        .font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                LabeledContent {
                    Button("Clear History") { AgentUsageStore.shared.clearHistory() }
                } label: {
                    RowLabel(title: "Usage history",
                             subtitle: "Kept on this Mac by the hour, so it outlives the agents' own logs. API values use published per-token prices as of \(AgentPricing.updated); local models aren't priced.")
                }
            } header: {
                Text("History")
            }
            Section {
                ForEach(AgentMonitor.Tool.allCases) { tool in
                    HStack(spacing: 10) {
                        AgentGlyph(tool: tool, size: 22)
                        RowLabel(title: tool.name, subtitle: source(tool))
                        Spacer()
                        Text(agents.installed.contains(tool) ? "Found" : "Not found")
                            .font(.caption).foregroundStyle(agents.installed.contains(tool) ? Color.green : Color.secondary)
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                FooterText("Read-only, from files these tools already keep on your Mac. Nothing is sent anywhere.")
            }
        }
        .onAppear { agents.refreshSessions() }
    }

    private func planNote(_ tool: AgentMonitor.Tool) -> String {
        guard let plan = AgentUsageStore.shared.plan(for: tool) else { return "No plan recorded: pick one to compare value" }
        let price = plan.monthly.map { " · $\(Int($0))/mo" } ?? ""
        return plan.name + price + (plan.detected ? " · detected" : "")
    }

    private func source(_ tool: AgentMonitor.Tool) -> String {
        switch tool {
        case .claude: "~/.claude: live session status and transcript usage"
        case .codex: "~/.codex/sessions: rollouts and token counts"
        case .opencode: "~/.local/share/opencode/opencode.db"
        case .zcode: "~/.zcode/cli/db: turns and per-model usage"
        }
    }
}

private struct AgentPlanRow: View {
    let tool: AgentMonitor.Tool
    let installed: Bool
    let note: String
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            AgentGlyph(tool: tool, size: 22)
            RowLabel(title: tool.name, subtitle: installed ? note : "Not found on this Mac")
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { s.agentPlans[tool.rawValue] ?? "" },
                set: { s.agentPlans[tool.rawValue] = $0.isEmpty ? nil : $0 })) {
                Text("Automatic").tag("")
                Divider()
                ForEach(AgentPlan.choices(for: tool)) { plan in
                    Text(plan.monthly.map { "\(plan.name) · $\(Int($0))/mo" } ?? plan.name).tag(plan.id)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Settings › Controls › Quick actions: the Controls grid as it appears in the notch. Drag tiles
/// to reorder them, drag new ones in from the palette, drag them back out (or ⌫) to remove.
private struct ControlsPane: View {
    @EnvironmentObject private var s: AppSettings
    @StateObject private var editor = QuickActionsEditor()
    @State private var origin: CGPoint = .zero

    var body: some View {
        SettingsPage(pane: .controls) {
            Section {
            } footer: {
                FooterText("Dark Mode and Empty Trash ask once for permission to control System Events and Finder.")
            }
            QuickActionsSection(editor: editor)
            Section("Keep Awake") {
                ToggleRow("Keep the display on", subtitle: "Off lets the screen sleep while the Mac itself stays awake (downloads, renders).",
                          isOn: $s.keepAwakeDisplay)
                Picker(selection: $s.keepAwakeBatteryFloor) {
                    Text("Never").tag(0)
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("30%").tag(30)
                    Text("50%").tag(50)
                } label: {
                    RowLabel(title: "Stop on battery below", subtitle: "So a forgotten session doesn't drain your battery.")
                }
            }
            Section("Camera") {
                ToggleRow("Camera mirror button", subtitle: "A camera button in the notch shows a mirrored preview. The camera only runs while it's open.",
                          isOn: $s.cameraMirrorEnabled)
            }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
        // A gallery tile being dragged floats above everything, following the pointer.
        .overlay(alignment: .topLeading) {
            if let action = editor.incoming {
                QuickActionDragTile(action: action, landing: editor.incomingTarget != nil)
                    .position(x: editor.location.x - origin.x, y: editor.location.y - origin.y)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct MousePane: View {
    @EnvironmentObject private var s: AppSettings
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPage(pane: .mouse) {
            Section {
                ToggleRow("Reverse mouse wheel scrolling",
                          subtitle: "Scroll a mouse wheel the traditional way while the trackpad keeps natural scrolling. Magic Mouse counts as a trackpad.",
                          isOn: $s.reverseMouseScroll)
                ToggleRow("Three-finger click for middle click",
                          subtitle: "Click the trackpad with three fingers to open links in new tabs, close tabs, paste in Terminal…",
                          isOn: $s.threeFingerMiddleClick)
            }
            Section("Permission") {
                PermissionRow(title: "Accessibility", subtitle: trusted ? nil : "Needed to adjust scroll and click events.",
                              state: trusted ? .granted : .unknown) {
                    HUDController.shared.requestAccessibility()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }
}

private struct UpdatesPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        SettingsPage(pane: .updates) {
            Section {
                ToggleRow("Check for updates", subtitle: "Every six hours. Review and install them from the Controls tab.", isOn: $s.updateChecks)
                if s.updateChecks {
                    ToggleRow("Include apps that update themselves", subtitle: "Apps using Sparkle, like IINA, Rectangle and HandBrake.",
                              isOn: $s.updateChecksApps)
                    ToggleRow("Alert when new updates appear", isOn: $s.updateAlerts)
                }
            }
            if s.updateChecks {
                Section {
                    LabeledContent {
                        HStack(spacing: 10) {
                            if updates.checking { ProgressView().controlSize(.small) }
                            Button("Check Now") { updates.check() }.disabled(updates.checking)
                        }
                    } label: {
                        RowLabel(title: updates.updates.isEmpty ? "No updates found" : "\(updates.updates.count) available",
                                 subtitle: updates.lastChecked.map { "Last checked " + $0.formatted(.relative(presentation: .named)) })
                    }
                    if UpdateChecker.brew == nil {
                        Text("Homebrew isn't installed, so only self-updating apps are checked.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct ShortcutsPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var hotKeys = HotKeys.shared
    @State private var recording: HotKeys.Action?
    @State private var filter = ""
    /// Said after a recording took keys from another action, which got this one's old keys.
    @State private var notice: String?

    private var shown: [HotKeys.Action] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return HotKeys.Action.allCases }
        return HotKeys.Action.allCases.filter { action in
            action.title.lowercased().contains(q)
                || (HotKeys.combo(for: action).map { $0.display.lowercased().contains(q) || $0.key.lowercased() == q } ?? false)
        }
    }

    var body: some View {
        SettingsPage(pane: .shortcuts) {
            Section {
                ToggleRow("Keyboard shortcuts", subtitle: "Press one again while its tab is showing to close the notch.", isOn: $s.hotKeysEnabled)
                if s.hotKeysEnabled {
                    Picker(selection: $s.hotKeyModifiers) {
                        ForEach(HotKeys.Modifiers.allCases) { Text($0.title).tag($0) }
                    } label: {
                        RowLabel(title: "Default modifier keys", subtitle: "For every shortcut you haven't changed. ⌥⌘ matches other notch apps but overrides some app shortcuts (⌥⌘D hides the Dock). "
                                 + "✦ Hyper is ⌃⌥⇧⌘ together, for a Caps Lock remapped with Karabiner or Raycast.")
                    }
                    .pickerStyle(.segmented)
                }
            }
            if s.hotKeysEnabled {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                        TextField("Filter by name or key", text: $filter)
                            .textFieldStyle(.plain)
                        if !filter.isEmpty {
                            Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.borderless)
                        }
                    }
                    if shown.isEmpty {
                        Text("No shortcuts match “\(filter)”")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(shown) { action in
                        LabeledContent {
                            HStack(spacing: 6) {
                                if let problem = problem(for: action) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.yellow)
                                        .help(problem)
                                }
                                ShortcutRecorder(action: action, recording: $recording) { notice = $0 }
                                Button {
                                    s.hotKeyOverrides[action.rawValue] = nil
                                } label: {
                                    Image(systemName: "arrow.uturn.backward.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Reset to \(action.defaultCombo(s.hotKeyModifiers).display)")
                                .opacity(s.hotKeyOverrides[action.rawValue] == nil ? 0 : 1)
                                .disabled(s.hotKeyOverrides[action.rawValue] == nil)
                            }
                        } label: {
                            Text(action.title)
                                .foregroundStyle(HotKeys.combo(for: action) == nil ? .secondary : .primary)
                        }
                        .contextMenu {
                            Button("Record New Shortcut") { recording = action }
                            Button("Turn Off") { s.hotKeyOverrides[action.rawValue] = HotKeys.Combo.off }
                                .disabled(HotKeys.combo(for: action) == nil)
                            Button("Restore Default (\(action.defaultCombo(s.hotKeyModifiers).display))") {
                                s.hotKeyOverrides[action.rawValue] = nil
                            }
                            .disabled(s.hotKeyOverrides[action.rawValue] == nil)
                        }
                    }
                } header: {
                    HStack {
                        Text("Shortcuts")
                        Spacer()
                        // Turning everything off, then picking the few you want, keeps stray presses harmless.
                        if HotKeys.Action.allCases.contains(where: { HotKeys.combo(for: $0) != nil }) {
                            Button("Turn Off All") {
                                s.hotKeyOverrides = Dictionary(uniqueKeysWithValues: HotKeys.Action.allCases.map { ($0.rawValue, HotKeys.Combo.off) })
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        if !s.hotKeyOverrides.isEmpty {
                            Button("Restore Defaults") { s.hotKeyOverrides = [:] }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                } footer: {
                    FooterText(notice ?? "Click a shortcut and press new keys, or ⎋ to cancel. Click ✕ (or press ⌫ while recording) to turn one off. Keys another shortcut uses are swapped with it.")
                }
            }
        }
        .onDisappear { recording = nil }
        .onChange(of: notice) { _, text in
            guard let text else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if notice == text { notice = nil } }
        }
    }

    /// Why a shortcut won't work, if it won't: another action has it, or another app does.
    private func problem(for action: HotKeys.Action) -> String? {
        guard let combo = HotKeys.combo(for: action) else { return nil }
        if let other = HotKeys.Action.allCases.first(where: { $0 != action && HotKeys.combo(for: $0) == combo }) {
            return "\(combo.display) is also used for “\(other.title)”."
        }
        if hotKeys.failed.contains(action) { return "\(combo.display) is in use by another app or macOS." }
        return nil
    }
}

/// A shortcut field: shows the keys, and records new ones when clicked (like System Settings' fields).
private struct ShortcutRecorder: View {
    let action: HotKeys.Action
    @Binding var recording: HotKeys.Action?
    /// Called with a message when recording swapped keys with another action.
    var swapped: (String) -> Void = { _ in }
    @EnvironmentObject private var s: AppSettings
    @State private var monitor: Any?
    @State private var held: String = ""
    @State private var hovering = false

    private var isRecording: Bool { recording == action }

    var body: some View {
        // The field and its turn-off ✕ are sibling buttons (a button nested in another never gets
        // the click). Plain tap gestures don't work here: Form rows don't pass them clicks.
        ZStack {
            Button {
                recording = isRecording ? nil : action
            } label: {
                Group {
                    if isRecording {
                        Text(held.isEmpty ? "Type Shortcut" : held)
                            .foregroundStyle(held.isEmpty ? .secondary : .primary)
                    } else if let combo = HotKeys.combo(for: action) {
                        Text(combo.display)
                    } else {
                        Text("None").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 22)
                .frame(width: 124, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hovering ? 0.09 : 0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isRecording ? 1.5 : 0.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shortcut for \(action.title)")
            HStack {
                Spacer()
                if hovering, !isRecording, HotKeys.combo(for: action) != nil {
                    Button {
                        s.hotKeyOverrides[action.rawValue] = HotKeys.Combo.off
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Turn off this shortcut")
                    .accessibilityLabel("Turn off shortcut for \(action.title)")
                    .transition(.opacity)
                }
            }
            .padding(.trailing, 2)
        }
        .frame(width: 124, height: 22)

        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(isRecording ? "Press keys, ⌫ to turn off, ⎋ to cancel" : "Click to change")
        .onChange(of: isRecording) { _, on in on ? start() : stop() }
        .onDisappear { stop() }
    }

    private func start() {
        held = ""
        HotKeys.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            switch event.type {
            case .leftMouseDown:
                // Clicking anywhere else ends recording; the click still goes through.
                DispatchQueue.main.async { if recording == action { recording = nil } }
                return event
            case .flagsChanged:
                held = (HotKeys.Combo(keyCode: 0, modifiers: carbon(event.modifierFlags), key: "x").modifierSymbols)
                return nil
            default:
                let bare = event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
                if event.keyCode == UInt16(kVK_Escape), bare {
                    recording = nil
                } else if [UInt16(kVK_Delete), UInt16(kVK_ForwardDelete)].contains(event.keyCode), bare {
                    set(.off)
                } else if let combo = HotKeys.Combo(event: event) {
                    set(combo)
                } else {
                    NSSound.beep()
                }
                return nil
            }
        }
    }

    private func set(_ combo: HotKeys.Combo) {
        let old = HotKeys.combo(for: action)
        var overrides = s.hotKeyOverrides
        // Keys another action has: it takes this one's old keys (or none), so nothing clashes.
        if !combo.isNone, combo != old,
           let other = HotKeys.Action.allCases.first(where: { $0 != action && HotKeys.combo(for: $0) == combo }) {
            let given = old ?? HotKeys.Combo.off
            overrides[other.rawValue] = given == other.defaultCombo(s.hotKeyModifiers) ? nil : given
            swapped(old.map { "Swapped with “\(other.title)”, which is now \($0.display)." } ?? "“\(other.title)” had \(combo.display), so it's now off.")
        }
        // Back to the default? Then it's not an override any more, and follows the default modifiers.
        overrides[action.rawValue] = combo == action.defaultCombo(s.hotKeyModifiers) ? nil : combo
        s.hotKeyOverrides = overrides
        recording = nil
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = ""
        if recording == nil { HotKeys.shared.suspended = false }
    }

    private func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if flags.contains(.control) { out |= UInt32(controlKey) }
        if flags.contains(.option) { out |= UInt32(optionKey) }
        if flags.contains(.shift) { out |= UInt32(shiftKey) }
        if flags.contains(.command) { out |= UInt32(cmdKey) }
        return out
    }
}

private struct AboutPane: View {
    @ObservedObject private var updater = AppUpdater.shared
    @State private var token = ""
    @State private var hasToken = KeychainItem.get("github-token") != nil
    @State private var crashes = CrashReports.all().prefix(5).map { $0 }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                    .padding(.top, 48)
                Text("NotchApp")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.top, 14)
                Text("Your notch, but useful.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(version)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                updateStatus.padding(.top, 18)

                VStack(alignment: .leading, spacing: 18) {
                    if !AppUpdater.hasGitHubCLI { tokenRow }
                    if !crashes.isEmpty { crashList }
                }
                .frame(maxWidth: 520)
                .padding(.top, 30)

                Button("Quit NotchApp") { NSApp.terminate(nil) }
                    .controlSize(.large)
                    .padding(.vertical, 28)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .idle, .upToDate, .failed:
            VStack(spacing: 6) {
                Button("Check for Updates") { updater.check() }
                    .controlSize(.large)
                Group {
                    if case .upToDate = updater.state {
                        Label("You're up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if case .failed(let message) = updater.state {
                        Text(message).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 420)
                    } else if let last = updater.lastChecked {
                        Text("Checked \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
        case .available(let release):
            VStack(spacing: 8) {
                Text("NotchApp \(release.version) is available").font(.headline)
                if !release.notes.isEmpty {
                    Text(release.notes).font(.caption).foregroundStyle(.secondary).lineLimit(6).frame(maxWidth: 420)
                }
                Button("Install & Restart") { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .installing(let stage):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(stage).foregroundStyle(.secondary) }
        }
    }

    /// The repo's private: without the GitHub CLI, a token lets update checks in.
    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GitHub access").font(.headline)
            Text("Updates come from \(AppUpdater.repo), which is private. Sign in with the GitHub CLI (gh auth login), or paste a token that can read it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if hasToken {
                    Label("Token saved", systemImage: "key.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Remove") { KeychainItem.set(nil, for: "github-token"); hasToken = false }
                } else {
                    SecureField("", text: $token, prompt: Text("github_pat_…")).textFieldStyle(.roundedBorder)
                    Button("Save") { KeychainItem.set(token, for: "github-token"); token = ""; hasToken = true; updater.check() }
                        .disabled(token.isEmpty)
                }
            }
        }
    }

    /// Recent crashes: a summary to copy (for a bug report), or the full report.
    private var crashList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Crash reports").font(.headline)
            Text("Kept on this Mac. Copy a summary to report a problem.").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(crashes.enumerated()), id: \.element.id) { i, report in
                    HStack {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(report.date.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Button("Copy Summary") { CrashReports.copySummary(report) }.buttonStyle(.borderless)
                        Button("Show") { CrashReports.reveal(report) }.buttonStyle(.borderless)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    if i < crashes.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }
}
