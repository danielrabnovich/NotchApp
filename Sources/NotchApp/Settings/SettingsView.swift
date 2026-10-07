import AppKit
import EventKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environmentObject(AppSettings.shared)
                .environmentObject(CalendarManager.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "NotchApp Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 640, height: 480))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case media = "Media"
    case hud = "HUD"
    case battery = "Battery"
    case shelf = "Shelf"
    case tasks = "Tasks"
    case calendar = "Calendar"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .media: "music.note"
        case .hud: "speaker.wave.2.fill"
        case .battery: "battery.100.bolt"
        case .shelf: "tray.full.fill"
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .purple
        case .media: .pink
        case .hud: .blue
        case .battery: .green
        case .shelf: .orange
        case .tasks: .teal
        case .calendar: .red
        case .about: .indigo
        }
    }
}

struct SettingsView: View {
    @State private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { p in
                Label {
                    Text(p.rawValue)
                } icon: {
                    Image(systemName: p.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.tint.gradient))
                }
                .tag(p)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane()
                case .appearance: AppearancePane()
                case .media: MediaPane()
                case .hud: HUDPane()
                case .battery: BatteryPane()
                case .shelf: ShelfPane()
                case .tasks: TasksPane()
                case .calendar: CalendarPane()
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.rawValue)
        }
        .frame(minWidth: 620, minHeight: 440)
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @EnvironmentObject private var s: AppSettings
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Behavior") {
                Picker("Open notch on", selection: $s.openMode) {
                    ForEach(AppSettings.OpenMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if s.openMode == .hover {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $s.hoverDelay, in: 0...1, step: 0.05)
                            Text(String(format: "%.2fs", s.hoverDelay))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
            Section("Displays") {
                Picker("Show notch on", selection: $s.displayMode) {
                    ForEach(AppSettings.DisplayMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Fake notch on displays without one", isOn: $s.showFakeNotch)
            }
            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        LaunchAtLogin.isEnabled = v
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                Toggle("Show menu bar icon", isOn: $s.showMenuBarIcon)
                if !s.showMenuBarIcon {
                    Text("Right-click the notch, or open NotchApp again from Finder, to get back here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AppearancePane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        Form {
            Section("Color") {
                Picker("Accent color", selection: $s.accentMode) {
                    ForEach(AppSettings.AccentMode.allCases) { Text($0.label).tag($0) }
                }
                if s.accentMode == .custom {
                    ColorPicker("Custom color", selection: Binding(get: { s.customAccent }, set: { s.customAccent = $0 }),
                                supportsOpacity: false)
                }
            }
            Section("Motion") {
                Picker("Animation", selection: $s.animationStyle) {
                    ForEach(AppSettings.AnimationStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Drop shadow when open", isOn: $s.showShadow)
            }
        }
    }
}

private struct MediaPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Music player", isOn: $s.musicEnabled)
                Toggle("Show live activity while playing", isOn: $s.musicLiveActivity)
                    .disabled(!s.musicEnabled)
                Toggle("Audio visualizer", isOn: $s.showVisualizer)
                    .disabled(!s.musicEnabled)
            } footer: {
                Text("Works with Apple Music, Spotify, Podcasts, and browsers (YouTube, SoundCloud…). Click the album art to jump to the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HUDPane: View {
    @EnvironmentObject private var s: AppSettings
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Volume HUD", isOn: $s.volumeHUD)
                Toggle("Brightness HUD", isOn: $s.brightnessHUD)
            } footer: {
                Text("Shows volume and brightness changes in the notch instead of the system overlay. Shift + Option + key adjusts in finer steps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permission") {
                LabeledContent("Accessibility") {
                    if trusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") {
                            HUDController.shared.requestAccessibility()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                if !trusted {
                    Text("Without Accessibility access, the notch HUD still appears but macOS shows its own overlay too.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }
}

private struct BatteryPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Charging animation when plugged in", isOn: $s.chargingAnimation)
            }
        }
    }
}

private struct ShelfPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("File shelf", isOn: $s.shelfEnabled)
                Toggle("Catch new screenshots", isOn: $s.screenshotCatcher)
                    .disabled(!s.shelfEnabled)
                Toggle("AirDrop drop zone", isOn: $s.airDropZone)
                    .disabled(!s.shelfEnabled)
            } footer: {
                Text("Drag files onto the notch to park them, then drag them out to any app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TasksPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Tasks tab", isOn: $s.tasksEnabled)
                Toggle("Show open task count beside the notch", isOn: $s.showTaskCount)
                    .disabled(!s.tasksEnabled)
            } footer: {
                Text("Drag text, links, emails or files onto the notch and drop them on “Add to Tasks”. Click a task's circle to complete it, or click-and-drag a row right to complete, left to delete. Swipe with two fingers to move between tabs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CalendarPane: View {
    @EnvironmentObject private var s: AppSettings
    @EnvironmentObject private var calendar: CalendarManager

    var body: some View {
        Form {
            Section {
                Toggle("Show today's events", isOn: $s.calendarEnabled)
                Toggle("Upcoming meeting alerts", isOn: $s.meetingAlerts)
                    .disabled(!s.calendarEnabled)
                Stepper("Alert \(s.meetingAlertMinutes) min before", value: $s.meetingAlertMinutes, in: 1...30)
                    .disabled(!s.calendarEnabled || !s.meetingAlerts)
            }
            Section("Permission") {
                LabeledContent("Calendar access") {
                    if calendar.hasAccess {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { calendar.requestAccess() }
                    }
                }
            }
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("NotchApp")
                .font(.title.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("Your notch, but useful.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit NotchApp") { NSApp.terminate(nil) }
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
