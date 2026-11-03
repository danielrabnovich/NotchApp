import AppKit
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
    // Features in the order of the notch's pages (Search, Home, Shelf, Tasks, Timer, Controls,
    // Stats, Tools, Agents), then the ones that aren't pages.
    case assistant = "Assistant"
    case home = "Home"
    case shelf = "Shelf"
    case tasks = "Tasks"
    case timer = "Timer"
    case controls = "Controls"
    case stats = "Stats"
    case tools = "Tools"
    case agents = "Agents"
    case developer = "Developer"
    case hud = "HUD"
    case battery = "Battery"
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
        case .home: "What's on Home and in what order: music, your day, the weather and more. Plus music, calendar and meeting settings."
        case .hud: "Volume and brightness changes in the notch, and the Sound tab's per-app volume."
        case .battery: "What the notch does when you plug in."
        case .shelf: "Drag files onto the notch to park them, then out to any app. Screenshots and downloads land here too."
        case .tasks: "Your list, reminders and a scratchpad. Drop text, links or emails on the notch to add them."
        case .timer: "Countdowns, Pomodoro and a stopwatch. Scroll the ruler or pick a preset."
        case .stats: "CPU, GPU, memory, temperatures and power. Click a card for details."
        case .tools: "Network and speed test, a cleaner, an app uninstaller and Bluetooth batteries."
        case .agents: "Claude Code, Codex, OpenCode and ZCode sessions (working, waiting for you or idle) and today's tokens."
        case .developer: "GitHub in the notch: reviews waiting on you, your pull requests, and a ring that follows Actions after you push."
        case .addOns: "Search, Shelf and Tasks are always there. Turn on anything else you want."
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
        case .home: "house.fill"
        case .hud: "speaker.wave.2.fill"
        case .battery: "battery.100.bolt"
        case .shelf: "tray.full.fill"
        case .tasks: "checklist"
        case .timer: "timer"
        case .stats: "gauge.with.dots.needle.50percent"
        case .tools: "wrench.and.screwdriver.fill"
        case .agents: "sparkles.rectangle.stack.fill"
        case .developer: "arrow.triangle.pull"
        case .addOns: "puzzlepiece.extension.fill"
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
        case .home: .pink
        case .hud: .blue
        case .battery: .green
        case .shelf: .orange
        case .tasks: .teal
        case .timer: Color(red: 1, green: 0.55, blue: 0.15)
        case .stats: .cyan
        case .tools: Color(red: 0.95, green: 0.45, blue: 0.55)
        case .agents: .purple
        case .developer: Color(red: 0.2, green: 0.6, blue: 0.35)
        case .addOns: .indigo
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
                case .home: HomeSettingsPane()
                case .hud: HUDPane()
                case .battery: BatteryPane()
                case .shelf: ShelfSettingsPane()
                case .tasks: TasksSettingsPane()
                case .timer: TimerPane()
                case .stats: StatsPane()
                case .tools: ToolsSettingsPane()
                case .agents: AgentsSettingsPane()
                case .developer: DeveloperSettingsPane()
                case .addOns: AddOnsPane()
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
