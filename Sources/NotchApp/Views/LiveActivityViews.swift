import EventKit
import SwiftUI
import UniformTypeIdentifiers

/// One side of the closed notch with its pinned Glances: hugging the outer edge, where the
/// notch's rounded corners are, rather than the hardware notch. Each one is a button.
struct LiveSide: View {
    let row: GlanceRow
    let side: LiveSlot.Side
    let viewModel: NotchViewModel

    var body: some View {
        let h = viewModel.notchSize.height
        HStack(spacing: LiveActivities.spacing) {
            if side == .left, row.overflow > 0 { overflow }
            ForEach(row.items, id: \.item) { entry in
                GlanceButton(item: entry.item, viewModel: viewModel) {
                    // On whole pixels: a side's Glances can land on quarter points.
                    LiveItemView(item: entry.item, notchHeight: h, compact: entry.compact, side: side)
                        .pixelSnapped()
                }
                .frame(width: entry.item.width(notchHeight: h, compact: entry.compact), height: h)
                // Fades in once its neighbours have made room, not on top of them.
                .transition(.asymmetric(insertion: .scale(scale: 0.5).combined(with: .opacity.animation(.easeOut(duration: 0.18).delay(0.16))),
                                        removal: .scale(scale: 0.5).combined(with: .opacity)))
            }
            if side == .right, row.overflow > 0 { overflow }
        }
        .padding(side == .left ? .leading : .trailing, LiveActivities.outerPadding)
        .padding(side == .left ? .trailing : .leading, LiveActivities.innerPadding)
        .frame(maxWidth: .infinity, alignment: side == .left ? .leading : .trailing)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: row)
    }

    /// The Glances that didn't fit; a click opens the notch.
    private var overflow: some View {
        Text("+\(row.overflow)")
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: LiveActivities.overflowWidth, height: 16)
            .background(Capsule().fill(.white.opacity(0.1)))
            .help("\(row.overflow) more: there's no room beside the notch on this screen")
    }
}

/// A Glance as a button: a soft highlight on hover, its action on click (play/pause, pause the
/// timer, join the meeting…), and its options on right-click.
struct GlanceButton<Label: View>: View {
    let item: LiveItem
    let viewModel: NotchViewModel
    @ViewBuilder let label: () -> Label
    @ObservedObject private var live = LiveActivities.shared
    @State private var hovering = false
    @State private var pressed = false
    @State private var longPressed = false

    var body: some View {
        label()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Capsule()
                    .fill(.white.opacity(pressed ? 0.18 : hovering ? 0.1 : 0))
                    .padding(.horizontal, -5)
                    .padding(.vertical, 4)
            }
            .scaleEffect(pressed ? 0.94 : 1)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(CollapsedNotchView.space)).midX } action: { viewModel.glanceMidX[item] = $0 }
            .onHover { inside in
                hovering = inside
                viewModel.hoverGlance(item, inside)
            }
            .onTapGesture {
                // Releasing a long press also ends as a tap; that one's already been handled.
                if longPressed { longPressed = false; return }
                viewModel.endGlancePeek()
                Haptics.tap()
                GlanceActions.perform(item, in: viewModel)
                Tips.shared.note(.glanceClicked)
            }
            // Press and hold: open the notch on this Glance's details instead.
            .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 6) {
                longPressed = true
                Haptics.level()
                GlanceActions.openDetail(item, in: viewModel)
                Tips.shared.note(.glanceHeld)
            } onPressingChanged: { pressed = $0 }
            .contextMenu { GlanceMenu(item: item, viewModel: viewModel) }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
    }
}

/// A Glance's right-click: its action, its own options, then where it sits.
private struct GlanceMenu: View {
    let item: LiveItem
    let viewModel: NotchViewModel
    @ObservedObject private var live = LiveActivities.shared

    var body: some View {
        MenuItem(GlanceActions.hint(for: item), item.icon) { GlanceActions.perform(item, in: viewModel) }
        if GlanceActions.hasDetail(item) {
            MenuItem("Open in Notch", "rectangle.expand.vertical") { GlanceActions.openDetail(item, in: viewModel) }
        }
        if item == .duo { DuoSoundMenu() }
        if item == .meeting { MeetingMenu(viewModel: viewModel) }
        Divider()
        if let slot = live.slot(for: item) { placement(slot) }
        MenuItem("Edit Glances…", "capsule.on.rectangle") { SettingsWindowController.shared.show(pane: .live) }
    }

    @ViewBuilder private func placement(_ slot: LiveSlot) -> some View {
        Toggle(isOn: Binding(get: { slot.compact }, set: { on in live.update(item) { $0.compact = on } })) {
            Label("Compact", systemImage: "rectangle.compress.vertical")
        }
        let other: LiveSlot.Side = slot.side == .left ? .right : .left
        MenuItem(other == .left ? "Move to Left Side" : "Move to Right Side", other == .left ? "arrow.left" : "arrow.right") {
            live.place(item, side: other, at: other == .left ? live.items(on: .left).count : 0)
        }
        .disabled(live.isFull(other))
        MenuItem("Remove", "minus.circle") { live.remove([item]) }
        Divider()
    }
}

/// Duo's right-click: where the sound goes (each output with its own symbol, AirPods by model),
/// as on DuoBar's popover, and Mute.
private struct DuoSoundMenu: View {
    @ObservedObject private var audio = AudioOutputManager.shared

    var body: some View {
        Menu {
            OutputDeviceItems()
        } label: {
            Label("Sound Output", systemImage: "hifispeaker")
        }
        Toggle(isOn: Binding(get: { audio.muted }, set: { AudioOutputManager.isMuted = $0 })) {
            Label("Mute", systemImage: "speaker.slash")
        }
    }
}

/// The Meeting Glance's right-click: the call app's own camera, hand and leave, captions and notes.
private struct MeetingMenu: View {
    let viewModel: NotchViewModel
    @ObservedObject private var captions = LiveCaptions.shared
    @ObservedObject private var meetings = MeetingMonitor.shared

    var body: some View {
        ForEach(MeetingControls.available(), id: \.self) { action in
            Button { MeetingControls.perform(action) } label: { Label(action.title, systemImage: action.symbol) }
        }
        if let call = meetings.call {
            MenuItem("Show \(call.app)", "macwindow") { MeetingControls.showCall() }
        }
        if LiveCaptions.isSupported {
            Divider()
            MenuItem(captions.showing ? "Hide Captions" : "Show Captions", "captions.bubble") { captions.toggleCaptions() }
            if captions.recording {
                MenuItem("Catch Me Up", "sparkles") {
                    viewModel.open(tab: .ask, takeKeyboard: false, reason: .click)
                    MeetingAssistant.shared.catchUp("catch me up")
                }
                MenuItem("Stop Recording", "stop.circle") { MeetingAssistant.shared.stopRecording() }
            } else {
                MenuItem(meetings.call?.inPerson == true ? "Record This Meeting" : "Record This Call", "record.circle") {
                    MeetingAssistant.shared.record()
                }
            }
        }
        MenuItem("Take Notes", "note.text") {
            let ramble = RambleStore.shared
            if let title = meetings.call?.title, !ramble.text.contains("Notes from \(title):") {
                ramble.text = (ramble.text.isEmpty ? "" : ramble.text + "\n\n") + "Notes from \(title):\n"
            }
            ramble.open()
        }
    }
}

/// What clicking a Glance does.
@MainActor
enum GlanceActions {
    static func hint(for item: LiveItem) -> String {
        switch item {
        case .music: MediaController.shared.isPlaying ? "Pause" : "Play"
        case .timer:
            switch TimerStore.shared.state {
            case .running: "Pause Timer"
            case .paused: "Resume Timer"
            case .idle: "Start Timer"
            }
        case .keepAwake: "Stop Keeping Awake"
        case .nextEvent: LiveActivities.nextEvent().flatMap(MeetingLinks.find) != nil ? "Join Meeting" : "Show Calendar"
        case .agents:
            AgentMonitor.shared.waiting.first != nil ? "Go to the Agent Waiting for You" : "Show Agents"
        case .cpu, .gpu, .memory, .temperature, .power, .battery, .rings: "Show in Stats"
        case .tasks: "Show Tasks"
        case .network: "Show Network"
        case .vpn: "Show VPN"
        case .devices, .privacy: "Show Devices"
        case .disk: "Show Cleaner"
        case .askScreen: "Ask About This Window"
        case .appAction: AppActions.shared.glanceActions.map(\.title).joined(separator: " · ")
        case .shortcuts: ShortcutsApp.shared.glanceShortcuts.map(\.name).joined(separator: " · ").nilIfEmpty ?? "Pick Shortcuts in Settings → Glances"
        case .duo: DuoGlyph.summary
        case .focus: FocusMonitor.shared.clickHint
        case .vercel: VercelService.shared.current != nil ? "Open the Build" : "Open the Latest Deployment"
        case .linear: LinearService.shared.inProgress.isEmpty ? "Open Your Top Issue" : "Open the Issue"
        case .github: GitHubService.shared.currentRun != nil ? "Open the Run" : GitHubService.shared.needsYouCount > 0 ? "Open What's Waiting" : "Open Pull Requests"
        case .meeting: ControlsService.shared.micMuted ? "Unmute Microphone" : "Mute Microphone"
        case .worldClock: "\(WorldClock.city.name) · \(WorldClock.offset(TimeZone(identifier: WorldClock.city.zone) ?? .current))"
        case .weather: TodayWeather.shared.report?.summary ?? "Weather"
        case .goldenHour: GoldenHour.now()?.detail ?? "Golden hour"
        case .unread: UnreadBadges.shared.badges.map { "\($0.name): \($0.count)" }.joined(separator: "\n").nilIfEmpty ?? "Nothing unread"
        case .countdown: Countdown.target.map { "\(AppSettings.shared.countdownTitle) · \($0.formatted(date: .complete, time: .omitted))" } ?? "Set a date in Settings → Glances"
        case .progress: ProgressCenter.shared.items.map { "\($0.title)\($0.fraction.map { " · \(Int($0 * 100))%" } ?? "")" }.joined(separator: "\n")
        case .quickDarkMode: ControlsService.shared.darkMode ? "Turn Dark Mode Off" : "Turn Dark Mode On"
        case .quickMic: ControlsService.shared.micMuted ? "Unmute Microphone" : "Mute Microphone"
        case .quickWiFi: ControlsService.shared.wifiOn ? "Turn Wi-Fi Off" : "Turn Wi-Fi On"
        case .quickNightShift: SystemTweaks.shared.nightShiftOn ? "Turn Night Shift Off" : "Turn Night Shift On"
        case .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock: item.title
        }
    }

    static func perform(_ item: LiveItem, in vm: NotchViewModel) {
        switch item {
        case .music:
            MediaController.shared.togglePlayPause()
        case .timer:
            let timer = TimerStore.shared
            switch timer.state {
            case .running: timer.pause()
            case .paused: timer.resume()
            case .idle: timer.start()
            }
        case .keepAwake:
            KeepAwake.shared.stop()
        case .nextEvent:
            if let link = LiveActivities.nextEvent().flatMap(MeetingLinks.find) { MeetingLinks.join(link) } else { openDetail(item, in: vm) }
        case .agents:
            let agents = AgentMonitor.shared
            if let waiting = agents.waiting.first { agents.focus(waiting) } else { openDetail(item, in: vm) }
        case .askScreen:
            HotKeys.askAboutScreen(vm, reason: .click)
        case .meeting:
            ControlsService.shared.toggleMic()
            Haptics.tap()
        case .progress:
            ProgressCenter.shared.open()
        case .worldClock:
            let city = WorldClock.city, zone = TimeZone(identifier: city.zone) ?? .current
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.timeZone = zone
            var day = Date.FormatStyle().weekday(.wide)
            day.timeZone = zone
            ActivityCenter.shared.show(.notice(title: "\(city.name) · \(Date().formatted(style))", detail: "\(Date().formatted(day)) · \(WorldClock.offset(zone))",
                                               icon: "globe", tone: .info), for: 3)
        case .weather:
            vm.open(tab: .ask, takeKeyboard: false, reason: .click)
            AssistantStore.shared.run("weather")
        case .goldenHour:
            if let reading = GoldenHour.now() {
                ActivityCenter.shared.show(.notice(title: reading.golden ? "Golden hour" : "Golden hour later", detail: reading.detail,
                                                   icon: reading.icon, tone: .info), for: 3.5)
            }
        case .unread:
            UnreadBadges.shared.openTop()
        case .countdown:
            if let target = Countdown.target {
                ActivityCenter.shared.show(.notice(title: "\(AppSettings.shared.countdownTitle) · \(Countdown.text())",
                                                   detail: target.formatted(date: .complete, time: .omitted), icon: "flag.checkered", tone: .info), for: 3)
            } else {
                SettingsWindowController.shared.show(pane: .live)
            }
        case .focus:
            FocusMonitor.shared.click()
        case .github:
            GitHubService.shared.openTop()
        case .vercel:
            VercelService.shared.openTop()
        case .linear:
            LinearService.shared.openTop()
        case .shortcuts:
            // One glyph: run it. Several: each glyph runs its own (see ShortcutGlyphs). None yet: pick some.
            let picked = ShortcutsApp.shared.glanceShortcuts
            if picked.isEmpty {
                SettingsWindowController.shared.show(pane: .live)
            } else if picked.count == 1 {
                ShortcutsApp.shared.run(picked[0])
            }
        case .appAction:
            // One glyph: run it. Several: each glyph runs its own (see AppActionGlyphs).
            if let only = AppActions.shared.glanceActions.first, AppActions.shared.glanceActions.count == 1 {
                AppActions.shared.runGlance(only, in: vm)
            }
        case let item where item.isAction:
            item.controlAction?.run()
        default:
            openDetail(item, in: vm)
        }
    }

    /// Whether "Open in Notch" adds anything: for the rest, clicking already opens the details.
    static func hasDetail(_ item: LiveItem) -> Bool { [.music, .timer, .nextEvent, .agents, .keepAwake].contains(item) }

    /// Opens the notch where this Glance's details are.
    static func openDetail(_ item: LiveItem, in vm: NotchViewModel) {
        let defaults = UserDefaults.standard
        let tab: NotchTab
        switch item {
        case .music, .nextEvent: tab = .home
        case .timer: tab = .timer
        case .tasks: defaults.set(TasksPane.tasks.rawValue, forKey: "tasks.pane"); tab = .tasks
        case .agents: tab = .agents
        case .keepAwake: tab = .controls
        case .cpu, .temperature, .rings: SystemMonitor.shared.requestCard(.cpu); tab = .stats
        case .gpu: SystemMonitor.shared.requestCard(.gpu); tab = .stats
        case .memory: SystemMonitor.shared.requestCard(.memory); tab = .stats
        case .power, .battery: SystemMonitor.shared.requestCard(.power); tab = .stats
        case .network: defaults.set(ToolsPane.network.rawValue, forKey: "tools.pane"); tab = .tools
        case .vpn: defaults.set(ToolsPane.vpn.rawValue, forKey: "tools.pane"); tab = .tools
        case .devices, .privacy: defaults.set(ToolsPane.devices.rawValue, forKey: "tools.pane"); tab = .tools
        case .disk: defaults.set(ToolsPane.cleaner.rawValue, forKey: "tools.pane"); tab = .tools
        case .askScreen, .appAction: tab = .ask
        case .duo: tab = .controls
        case .focus:
            FocusMonitor.shared.click()
            return
        case .shortcuts:
            SettingsWindowController.shared.show(pane: .live)
            return
        case .meeting, .github, .vercel, .linear: tab = .home
        case .progress: tab = .shelf
        case .weather: tab = .home
        case .worldClock, .goldenHour, .countdown, .unread:
            SettingsWindowController.shared.show(pane: .live)
            return
        case .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock, .quickDarkMode, .quickMic, .quickWiFi, .quickNightShift:
            tab = .controls
        }
        vm.open(tab: vm.tabs.contains(tab) ? tab : nil, takeKeyboard: false, reason: .click)
    }
}

/// A Glance: one glyph and one reading, the same type size throughout. Compact keeps just the
/// reading, a small gauge, or the glyph.
struct LiveItemView: View {
    let item: LiveItem
    let notchHeight: CGFloat
    var compact = false
    /// Which side of the notch it's on: a reading beside a glyph goes on the notch's side of it.
    var side: LiveSlot.Side = .left
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var media: MediaController
    @EnvironmentObject private var battery: BatteryMonitor
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var stats: SystemMonitor
    @EnvironmentObject private var timer: TimerStore

    var body: some View {
        if compact { compactBody } else { regularBody }
    }

    @ViewBuilder private var compactBody: some View {
        switch item {
        case .music:
            AlbumArtView(image: media.artwork, size: notchHeight - 14, cornerRadius: 5)
                .opacity(media.isPlaying ? 1 : 0.55)
        case .timer:
            TimerReadout(clock: TimerStore.shared.clock)
                .opacity(timer.isActive ? 1 : 0.45)
        case .cpu:
            Gauge(icon: "cpu", value: stats.snapshot.cpuTotal, tint: load(stats.snapshot.cpuTotal))
        case .gpu:
            Gauge(icon: "square.stack.3d.up.fill", value: stats.snapshot.gpu ?? 0, tint: load(stats.snapshot.gpu ?? 0))
        case .memory:
            let used = memoryUsed
            Gauge(icon: "memorychip", value: used, tint: load(used, warm: 0.85, hot: 0.95))
        case .temperature:
            let temp = stats.snapshot.cpuTemp
            Text(temp.map { "\(Int($0.rounded()))°" } ?? "–").font(Self.valueFont).fixedSize()
                .foregroundStyle(temp.map(heat) ?? .white.opacity(0.6))
        case .power:
            Text(watts(stats.snapshot.systemPower)).font(Self.valueFont).fixedSize()
                .foregroundStyle(.white.opacity(0.92))
        case .battery:
            BatteryGlyph(level: battery.level, charging: battery.isCharging, pluggedIn: battery.isPluggedIn,
                         lowPower: battery.lowPowerMode)
        case .nextEvent:
            NextEventReading(compact: true)
        case .network:
            NetworkReading(compact: true)
        case .devices:
            DeviceReading(compact: true)
        case .privacy:
            PrivacyReading()
        case .agents:
            AgentsReading(compact: true)
        case .vpn:
            VPNReading(compact: true)
        case .keepAwake:
            KeepAwakeReading(compact: true)
        case .disk:
            DiskReading(compact: true)
        case .meeting:
            MeetingReading(compact: true)
        case .progress:
            ProgressReading(compact: true)
        case .weather:
            WeatherGauge(diameter: min(22, notchHeight - 10))
        case .worldClock, .goldenHour, .unread, .countdown:
            ExtraReading(item: item, compact: true)
        case .tasks, .askScreen, .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock, .quickDarkMode, .quickMic,
             .quickWiFi, .quickNightShift, .appAction, .shortcuts:
            regularBody
        case .duo:
            DuoGlyph(diameter: min(22, notchHeight - 10))
        case .rings:
            StatRings(diameter: min(22, notchHeight - 10))
        case .focus:
            FocusReading(compact: true)
        case .github:
            GitHubReading(compact: true)
        case .vercel:
            VercelReading(compact: true)
        case .linear:
            LinearReading(compact: true)
        }
    }

    private var memoryUsed: Double {
        stats.snapshot.memory.total > 0 ? Double(stats.snapshot.memory.used) / Double(stats.snapshot.memory.total) : 0
    }

    /// "14W", or "6.5W" under ten.
    private func watts(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(formatSmall(value))W"
    }

    @ViewBuilder private var regularBody: some View {
        switch item {
        case .music:
            HStack(spacing: 6) {
                AlbumArtView(image: media.artwork, size: notchHeight - 14, cornerRadius: 5)
                    .opacity(media.isPlaying ? 1 : 0.55)
                AudioVisualizer(color: settings.accent(for: media), isPlaying: media.isPlaying, barCount: 4)
                    .frame(width: 16, height: 12)
                    .opacity(media.isPlaying ? 1 : 0.4)
            }
        case .timer:
            // Pinned "always": an idle timer waits, dimmed, until it's started.
            HStack(spacing: 6) {
                TimerRing(clock: TimerStore.shared.clock)
                TimerReadout(clock: TimerStore.shared.clock)
            }
            .opacity(timer.isActive ? 1 : 0.45)
        case .cpu:
            Reading(icon: "cpu", value: percent(stats.snapshot.cpuTotal), tint: load(stats.snapshot.cpuTotal),
                    meter: stats.snapshot.cpuTotal)
        case .gpu:
            Reading(icon: "square.stack.3d.up.fill", value: stats.snapshot.gpu.map(percent) ?? "–",
                    tint: load(stats.snapshot.gpu ?? 0), meter: stats.snapshot.gpu ?? 0)
        case .memory:
            let used = memoryUsed
            // macOS keeps memory busy on purpose: only warn when it's nearly full.
            Reading(icon: "memorychip", value: percent(used), tint: load(used, warm: 0.85, hot: 0.95), meter: used)
        case .power:
            Reading(icon: "bolt.fill", value: watts(stats.snapshot.systemPower), tint: .white.opacity(0.92))
        case .temperature:
            let temp = stats.snapshot.cpuTemp
            Reading(icon: "thermometer.medium", value: temp.map { "\(Int($0.rounded()))°" } ?? "–",
                    tint: temp.map(heat) ?? .white.opacity(0.6))
        case .battery:
            HStack(spacing: 5) {
                // Plugged in counts as on power even when macOS holds the charge ("not charging").
                let onPower = battery.isCharging || battery.isPluggedIn
                BatteryIcon(level: battery.level, charging: onPower, lowPower: battery.lowPowerMode)
                Text("\(battery.level)%")
                    .font(Self.valueFont)
                    .rollingDigits(battery.level)
                    .fixedSize()
                    .foregroundStyle(battery.level <= 20 && !onPower ? .red : .white.opacity(0.92))
            }
        case .nextEvent:
            NextEventReading()
        case .network:
            NetworkReading()
        case .devices:
            DeviceReading()
        case .privacy:
            PrivacyReading()
        case .agents:
            AgentsReading()
        case .vpn:
            VPNReading()
        case .keepAwake:
            KeepAwakeReading()
        case .disk:
            DiskReading()
        case .meeting:
            MeetingReading()
        case .progress:
            ProgressReading()
        case .weather:
            WeatherGauge(diameter: min(22, notchHeight - 10))
        case .worldClock, .goldenHour, .unread, .countdown:
            ExtraReading(item: item)
        case .askScreen, .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock, .quickDarkMode, .quickMic,
             .quickWiFi, .quickNightShift:
            ActionGlyph(item: item)
        case .appAction:
            AppActionGlyphs()
        case .shortcuts:
            ShortcutGlyphs()
        case .duo:
            towardNotch(DuoGlyph(diameter: min(22, notchHeight - 10)), DuoReading())
        case .rings:
            towardNotch(StatRings(diameter: min(22, notchHeight - 10)), RingsReading(alignment: side == .left ? .leading : .trailing))
        case .focus:
            FocusReading()
        case .github:
            GitHubReading()
        case .vercel:
            VercelReading()
        case .linear:
            LinearReading()
        case .tasks:
            Text("\(tasks.openCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.black)
                .frame(minWidth: 18, minHeight: 18)
                .background(Circle().fill(.white.opacity(0.9)))
        }
    }

    static let valueFont = Font.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()

    /// A glyph and its reading, the reading on the notch's side: numbers gather towards the middle.
    @ViewBuilder private func towardNotch(_ glyph: some View, _ reading: some View) -> some View {
        HStack(spacing: 5) {
            if side == .left {
                glyph
                reading
            } else {
                reading
                glyph
            }
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// White while things are calm, warming to orange and red under load.
    private func load(_ value: Double, warm: Double = 0.6, hot: Double = 0.85) -> Color {
        value > hot ? Color(red: 1, green: 0.38, blue: 0.35) : value > warm ? Color(red: 1, green: 0.7, blue: 0.3) : .white.opacity(0.92)
    }

    /// Cool blue when idle, white in the normal range, then orange and red.
    private func heat(_ celsius: Double) -> Color {
        switch celsius {
        case ..<45: Color(red: 0.5, green: 0.8, blue: 1)
        case ..<70: .white.opacity(0.92)
        case ..<85: Color(red: 1, green: 0.7, blue: 0.3)
        default: Color(red: 1, green: 0.38, blue: 0.35)
        }
    }

    /// A load as a small ring around its glyph (the compact CPU, GPU and memory).
    private struct Gauge: View {
        let icon: String
        let value: Double
        let tint: Color

        var body: some View {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: min(max(value, 0.03), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // Sized as an image, not as text: a symbol set in a font sits on its baseline, a
                // little below the ring's centre.
                Image(systemName: icon)
                    .resizable()
                    .fontWeight(.bold)
                    .scaledToFit()
                    .frame(width: 8, height: 8)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 17, height: 17)
            .help("\(Int((value * 100).rounded()))%")
        }
    }

    /// A glyph, a value, and (for loads) a thin meter under the glyph.
    private struct Reading: View {
        let icon: String
        let value: String
        let tint: Color
        var meter: Double?

        var body: some View {
            HStack(spacing: 5) {
                VStack(spacing: 2) {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    if let meter {
                        Capsule().fill(.white.opacity(0.15))
                            .frame(width: 13, height: 2)
                            .overlay(alignment: .leading) {
                                Capsule().fill(tint).frame(width: 13 * min(max(meter, 0.04), 1), height: 2)
                            }
                    }
                }
                // Changes in place, without rolling digits: it's always in view, so it stays calm.
                Text(value)
                    .font(LiveItemView.valueFont)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}
