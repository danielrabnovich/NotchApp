import AppKit
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
            w.setContentSize(NSSize(width: 780, height: 580))
            w.contentMinSize = NSSize(width: 700, height: 480)
            w.center()
            w.setFrameAutosaveName("NotchAppSettings")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
    case appearance = "Appearance"
    case assistant = "Assistant"
    case media = "Media"
    case hud = "HUD"
    case battery = "Battery"
    case shelf = "Shelf"
    case tasks = "Tasks"
    case timer = "Timer"
    case stats = "Stats"
    case calendar = "Calendar"
    case controls = "Controls"
    case mouse = "Mouse"
    case updates = "Updates"
    case shortcuts = "Shortcuts"
    case about = "About"

    var id: String { rawValue }

    enum Group: String, CaseIterable { case app = "NotchApp", features = "Features", info = "" }

    var group: Group {
        switch self {
        case .general, .appearance, .shortcuts: .app
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
        case .assistant: "Find files, search the web and check the weather, with optional local AI."
        case .media: "Now playing, the visualizer and per-app volume."
        case .hud: "Show volume and brightness changes in the notch."
        case .battery: "What the notch does when you plug in."
        case .shelf: "Park files, catch screenshots and see recent downloads."
        case .tasks: "Your list, reminders and a scratchpad."
        case .timer: "Countdowns, Pomodoro and a stopwatch."
        case .stats: "CPU, GPU, memory, temperatures and power."
        case .calendar: "Today's events and heads-ups before meetings."
        case .controls: "Quick toggles, sliders, Keep Awake and a camera mirror."
        case .mouse: "Scroll direction and middle click."
        case .updates: "Homebrew and app updates, checked for you."
        case .shortcuts: "Jump straight to any tab from anywhere."
        case .about: "Version and app info."
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .assistant: "sparkle.magnifyingglass"
        case .media: "music.note"
        case .hud: "speaker.wave.2.fill"
        case .battery: "battery.100.bolt"
        case .shelf: "tray.full.fill"
        case .tasks: "checklist"
        case .timer: "timer"
        case .stats: "gauge.with.dots.needle.50percent"
        case .calendar: "calendar"
        case .controls: "switch.2"
        case .mouse: "computermouse.fill"
        case .updates: "arrow.down.app.fill"
        case .shortcuts: "command"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .purple
        case .assistant: .indigo
        case .media: .pink
        case .hud: .blue
        case .battery: .green
        case .shelf: .orange
        case .tasks: .teal
        case .timer: Color(red: 1, green: 0.55, blue: 0.15)
        case .stats: .cyan
        case .calendar: .red
        case .controls: Color(red: 0.35, green: 0.35, blue: 0.4)
        case .mouse: Color(red: 0.4, green: 0.45, blue: 0.55)
        case .updates: .blue
        case .shortcuts: Color(red: 0.25, green: 0.5, blue: 0.95)
        case .about: .secondary
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $router.pane) {
                ForEach(SettingsPane.Group.allCases, id: \.self) { group in
                    Section {
                        ForEach(SettingsPane.allCases.filter { $0.group == group }) { p in
                            Label {
                                Text(p.title)
                            } icon: {
                                SettingsIcon(pane: p, size: 22)
                            }
                            .padding(.vertical, 1)
                            .tag(p)
                        }
                    } header: {
                        if !group.rawValue.isEmpty { Text(group.rawValue) }
                    }
                }
            }
            .frame(minWidth: 215)
            .navigationSplitViewColumnWidth(215)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch router.pane {
                case .general: GeneralPane()
                case .appearance: AppearancePane()
                case .assistant: AssistantPane()
                case .media: MediaPane()
                case .hud: HUDPane()
                case .battery: BatteryPane()
                case .shelf: ShelfSettingsPane()
                case .tasks: TasksSettingsPane()
                case .timer: TimerPane()
                case .stats: StatsPane()
                case .calendar: CalendarPane()
                case .controls: ControlsPane()
                case .mouse: MousePane()
                case .updates: UpdatesPane()
                case .shortcuts: ShortcutsPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle("")
            .animation(.easeInOut(duration: 0.18), value: router.pane)
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @EnvironmentObject private var s: AppSettings
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        SettingsPage(pane: .general) {
            Section("Opening") {
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
                    ToggleRow("Audio visualizer", isOn: $s.showVisualizer)
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
                Text("Hold Shift + Option while pressing a volume or brightness key for finer steps.")
                    .font(.caption).foregroundStyle(.secondary)
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
                ToggleRow("Shelf tab", subtitle: "Drag files onto the notch to park them, then drag them out to any app.",
                          isOn: $s.shelfEnabled)
                if s.shelfEnabled {
                    ToggleRow("Catch new screenshots", subtitle: "New screenshots land on the shelf automatically.", isOn: $s.screenshotCatcher)
                    ToggleRow("AirDrop drop zone", isOn: $s.airDropZone)
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
                ToggleRow("Tasks tab", subtitle: "Drop text, links, emails or files on the notch to add them. Drag a row right to complete, left to delete.",
                          isOn: $s.tasksEnabled)
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

private struct AssistantPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var assistant = AssistantStore.shared
    @ObservedObject private var folders = FolderAccess.shared
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

    var body: some View {
        SettingsPage(pane: .assistant) {
            Section {
                ToggleRow("Search tab", subtitle: "Works without AI: files by name, web results as links, and weather.",
                          isOn: $s.assistantEnabled)
                ToggleRow("Notify when a search finishes", subtitle: "A macOS notification if the notch is closed.",
                          isOn: $s.systemNotifications)
            } footer: {
                Text("With a local model through Ollama, search understands what you mean, picks the right file and writes answers. Everything stays on your Mac except web searches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Files & folders") {
                PermissionRow(title: "Desktop, Documents, Downloads & iCloud",
                              subtitle: folderSubtitle,
                              state: folderState,
                              request: { Task { await folders.recheck() } },
                              openSettings: { FolderAccess.openPrivacySettings() })
            }
            if assistant.pullingModel != nil || assistant.pullError != nil || assistant.justPulled != nil {
                Section { DownloadActivity() }
            }
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
            Section("Weather") {
                TextField(text: $s.homeCity, prompt: Text("e.g. Chapel Hill, NC")) {
                    RowLabel(title: "Home city", subtitle: "Used when you don't name a place.")
                }
            }
        }
        .task { assistant.refreshStatus() }
        .onChange(of: s.ollamaURL) { _, _ in assistant.refreshStatus() }
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
                ToggleRow("Timer tab", subtitle: "Scroll the ruler or click a preset to pick a length.", isOn: $s.timerEnabled)
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

    var body: some View {
        SettingsPage(pane: .stats) {
            Section {
                ToggleRow("Stats tab", subtitle: "Click a card for details. Updates every second while open, and every few seconds in the background.",
                          isOn: $s.statsEnabled)
                if s.statsEnabled {
                    Picker("Temperature", selection: $s.useFahrenheit) {
                        Text("Celsius").tag(false)
                        Text("Fahrenheit").tag(true)
                    }
                    .pickerStyle(.segmented)
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
                ToggleRow("Today's events", subtitle: "Shown next to the music player on the Home tab.", isOn: $s.calendarEnabled)
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
            Section("Permission") {
                PermissionRow(title: "Calendar", state: calendar.hasAccess ? .granted : .unknown) { calendar.requestAccess() }
            }
        }
    }
}

private struct ControlsPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .controls) {
            Section {
                ToggleRow("Controls tab", subtitle: "Volume and brightness sliders, Wi-Fi, Keep Awake, Dark Mode, mic mute, screenshot, color picker, lock screen and Empty Trash.",
                          isOn: $s.controlsEnabled)
            } footer: {
                Text("Dark Mode and Empty Trash ask once for permission to control System Events and Finder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

    var body: some View {
        SettingsPage(pane: .shortcuts) {
            Section {
                ToggleRow("Keyboard shortcuts", subtitle: "Press one again while its tab is showing to close the notch.", isOn: $s.hotKeysEnabled)
                if s.hotKeysEnabled {
                    Picker(selection: $s.hotKeyModifiers) {
                        ForEach(HotKeys.Modifiers.allCases) { Text($0.title).tag($0) }
                    } label: {
                        RowLabel(title: "Modifier keys", subtitle: "⌥⌘ matches other notch apps but overrides some app shortcuts (⌥⌘D hides the Dock). "
                                 + "✦ Hyper is ⌃⌥⇧⌘ together, for a Caps Lock remapped with Karabiner or Raycast.")
                    }
                    .pickerStyle(.segmented)
                }
            }
            if s.hotKeysEnabled {
                Section("Shortcuts") {
                    ForEach(HotKeys.Action.allCases) { action in
                        LabeledContent(action.title) {
                            Text("\(s.hotKeyModifiers.symbol) \(action.key)")
                                .font(.system(.callout, design: .rounded).weight(.medium).monospaced())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                        }
                    }
                }
            }
        }
    }
}

private struct AboutPane: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
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
            Spacer()
            Button("Quit NotchApp") { NSApp.terminate(nil) }
                .controlSize(.large)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
