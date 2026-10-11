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
                    LiveItemView(item: entry.item, notchHeight: h, compact: entry.compact)
                }
                .frame(width: entry.item.width(notchHeight: h, compact: entry.compact), height: h)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
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
            .onHover { hovering = $0 }
            .onTapGesture {
                // Releasing a long press also ends as a tap; that one's already been handled.
                if longPressed { longPressed = false; return }
                Haptics.tap()
                GlanceActions.perform(item, in: viewModel)
            }
            // Press and hold: open the notch on this Glance's details instead.
            .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 6) {
                longPressed = true
                Haptics.level()
                GlanceActions.openDetail(item, in: viewModel)
            } onPressingChanged: { pressed = $0 }
            .help(GlanceActions.hint(for: item))
            .contextMenu {
                Button(GlanceActions.hint(for: item)) { GlanceActions.perform(item, in: viewModel) }
                if GlanceActions.hasDetail(item) {
                    Button("Open in Notch") { GlanceActions.openDetail(item, in: viewModel) }
                }
                Divider()
                if let slot = live.slot(for: item) {
                    Toggle("Compact", isOn: Binding(get: { slot.compact }, set: { on in live.update(item) { $0.compact = on } }))
                    let other: LiveSlot.Side = slot.side == .left ? .right : .left
                    Button(other == .left ? "Move to Left Side" : "Move to Right Side") {
                        live.place(item, side: other, at: other == .left ? live.items(on: .left).count : 0)
                    }
                    .disabled(live.isFull(other))
                    Button("Remove") { live.remove([item]) }
                    Divider()
                }
                Button("Edit Glances…") { SettingsWindowController.shared.show(pane: .live) }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
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
        case .cpu, .gpu, .memory, .temperature, .power, .battery: "Show in Stats"
        case .tasks: "Show Tasks"
        case .network: "Show Network"
        case .vpn: "Show VPN"
        case .devices, .privacy: "Show Devices"
        case .disk: "Show Cleaner"
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
        case .cpu, .temperature: SystemMonitor.shared.requestCard(.cpu); tab = .stats
        case .gpu: SystemMonitor.shared.requestCard(.gpu); tab = .stats
        case .memory: SystemMonitor.shared.requestCard(.memory); tab = .stats
        case .power, .battery: SystemMonitor.shared.requestCard(.power); tab = .stats
        case .network: defaults.set(ToolsPane.network.rawValue, forKey: "tools.pane"); tab = .tools
        case .vpn: defaults.set(ToolsPane.vpn.rawValue, forKey: "tools.pane"); tab = .tools
        case .devices, .privacy: defaults.set(ToolsPane.devices.rawValue, forKey: "tools.pane"); tab = .tools
        case .disk: defaults.set(ToolsPane.cleaner.rawValue, forKey: "tools.pane"); tab = .tools
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
            BatteryIcon(level: battery.level, charging: battery.isCharging)
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
        case .tasks:
            regularBody
        }
    }

    private var memoryUsed: Double {
        stats.snapshot.memory.total > 0 ? Double(stats.snapshot.memory.used) / Double(stats.snapshot.memory.total) : 0
    }

    /// "14W", or "6.5W" under ten.
    private func watts(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value < 10 ? String(format: "%.1fW", value) : "\(Int(value.rounded()))W"
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
                BatteryIcon(level: battery.level, charging: battery.isCharging)
                Text("\(battery.level)%")
                    .font(Self.valueFont)
                    .fixedSize()
                    .foregroundStyle(battery.level <= 20 && !battery.isCharging ? .red : .white.opacity(0.92))
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
        case .tasks:
            Text("\(tasks.openCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.black)
                .frame(minWidth: 18, minHeight: 18)
                .background(Circle().fill(.white.opacity(0.9)))
        }
    }

    static let valueFont = Font.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()

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
                Image(systemName: icon)
                    .font(.system(size: 7, weight: .bold))
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

/// Download speed, with an arrow that lights up for whichever way is busier.
private struct NetworkReading: View {
    var compact = false
    @ObservedObject private var network = NetworkMonitor.shared

    var body: some View {
        let uploading = network.upRate > network.downRate * 1.5 && network.upRate > 50_000
        let r = formatRate(uploading ? network.upRate : network.downRate)
        HStack(spacing: compact ? 2 : 4) {
            Image(systemName: uploading ? "arrow.up" : "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(uploading ? ToolsPalette.up : ToolsPalette.down)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(r.value).font(LiveItemView.valueFont).foregroundStyle(.white.opacity(0.92))
                Text(compact ? String(r.unit.prefix(1)) : r.unit.replacingOccurrences(of: "/s", with: ""))
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}

/// The emptiest Bluetooth device's glyph and level.
private struct DeviceReading: View {
    var compact = false
    @ObservedObject private var devices = DeviceBatteries.shared

    var body: some View {
        if let device = devices.lowest, let level = device.level {
            let low = level <= 20
            HStack(spacing: 4) {
                Image(systemName: device.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(compact && low ? Color(red: 1, green: 0.38, blue: 0.35) : .white.opacity(0.7))
                if !compact {
                    Text("\(level)%")
                        .font(LiveItemView.valueFont)
                        .foregroundStyle(low ? Color(red: 1, green: 0.38, blue: 0.35) : .white.opacity(0.92))
                        .fixedSize()
                }
            }
            .help("\(device.name): \(level)%")
        }
    }
}

/// Agents at work: a spinner and how many; a raised hand when one is waiting for you.
private struct AgentsReading: View {
    var compact = false
    @ObservedObject private var agents = AgentMonitor.shared

    var body: some View {
        let waiting = agents.waiting.count, working = agents.working.count
        HStack(spacing: 4) {
            if waiting > 0 {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)
            } else if working > 0 {
                Image(systemName: "sparkle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(KeepAwakeReading.agentPurple)
            } else {
                Image(systemName: "sparkle").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            }
            if !compact {
                Text("\(waiting > 0 ? waiting : working)")
                    .font(LiveItemView.valueFont)
                    .foregroundStyle(waiting > 0 ? .orange : .white.opacity(0.92))
            }
        }
        .help(agents.sessions.filter { $0.state != .idle }.map { "\($0.tool.name) · \($0.project)" }.joined(separator: "\n"))
    }
}

/// A cup while the Mac is kept awake: time left for a timed session, "On" otherwise.
private struct KeepAwakeReading: View {
    var compact = false
    @ObservedObject private var keepAwake = KeepAwake.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(keepAwake.forAgents ? Self.agentPurple : Color(red: 0.92, green: 0.75, blue: 0.55))
                .fixedSize()
            if !compact {
                Text(keepAwake.endsAt == nil ? "On" : keepAwake.remainingText ?? "On")
                    .font(LiveItemView.valueFont)
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize()
            }
        }
        .help(keepAwake.forAgents ? "Awake while your agents work" : "Keep Awake")
    }
}

extension KeepAwakeReading {
    static let agentPurple = Color(red: 0.78, green: 0.6, blue: 1)
}

/// Free space on the startup disk; red under 10 GB.
private struct DiskReading: View {
    var compact = false
    @ObservedObject private var cleaner = Cleaner.shared

    var body: some View {
        let free = cleaner.disk?.available ?? 0
        HStack(spacing: 4) {
            if !compact {
                Image(systemName: "internaldrive.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
            Text(free >= 1_000_000_000_000 ? String(format: "%.1fT", Double(free) / 1e12) : "\(free / 1_000_000_000)G")
                .font(LiveItemView.valueFont)
                .foregroundStyle(free < 10_000_000_000 ? Color(red: 1, green: 0.38, blue: 0.35) : .white.opacity(0.92))
                .fixedSize()
        }
        .help("\(formatBytes(free)) free")
    }
}

/// A shield (green when all traffic is protected) and the exit country.
private struct VPNReading: View {
    var compact = false
    @ObservedObject private var vpn = VPNMonitor.shared

    var body: some View {
        let protected = vpn.connections.contains { $0.isUp && $0.fullTunnel }
        HStack(spacing: 4) {
            Image(systemName: protected ? "lock.shield.fill" : vpn.anyUp ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(protected ? Color.green : vpn.anyUp ? .white.opacity(0.7) : .orange)
            if !compact {
                Text(protected ? (vpn.exit?.countryCode?.uppercased() ?? "On") : vpn.anyUp ? "Split" : "Off")
                    .font(LiveItemView.valueFont)
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .help(vpn.active.map { "\($0.name)" + (vpn.exit.map { " · \($0.place)" } ?? "") } ?? "No VPN")
    }
}

/// An orange mic or green camera dot, like the menu bar's privacy indicator.
private struct PrivacyReading: View {
    @ObservedObject private var privacy = PrivacyMonitor.shared

    var body: some View {
        HStack(spacing: 3) {
            if privacy.cameraInUse {
                Image(systemName: "video.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
            }
            if privacy.micInUse {
                Image(systemName: "mic.fill").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.orange)
            }
        }
        .help(privacy.micApps.map(\.name).joined(separator: ", "))
    }
}

/// The next meeting: its calendar's color, then "in 12m" or its start time.
private struct NextEventReading: View {
    var compact = false
    @EnvironmentObject private var calendar: CalendarManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            if let event = LiveActivities.nextEvent(now: context.date) {
                let minutes = Int(event.startDate.timeIntervalSince(context.date) / 60)
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(cgColor: event.calendar.cgColor))
                        .frame(width: 7, height: 7)
                    Text(minutes < 60 ? (compact ? "\(max(minutes, 1))m" : "in \(max(minutes, 1))m")
                         : compact ? "\(minutes / 60)h" : event.startDate.formatted(date: .omitted, time: .shortened))
                        .font(LiveItemView.valueFont)
                        .foregroundStyle(minutes < 10 ? Color(cgColor: event.calendar.cgColor) : .white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .help(event.title ?? "")
            }
        }
    }
}

// MARK: - Settings

/// Settings › Live Activities: the notch itself, large, as the editor (drag activities to rearrange
/// or switch sides, down to remove, click one for its options), and a gallery to add them from by
/// clicking or dragging onto the notch. The notch stays put above the gallery as it scrolls.
struct LiveActivitiesPane: View {
    @ObservedObject private var live = LiveActivities.shared
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var gallery = GalleryDrag()
    @State private var origin: CGPoint = .zero

    var body: some View {
        SettingsPage(pane: .live) {
            NotchStage(gallery: gallery)
        } content: {
            Section {
                ActivityGallery(gallery: gallery)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                HStack {
                    Text("Glances")
                    Spacer()
                    if !live.slots.isEmpty {
                        Button("Remove All") { live.remove(live.slots.map(\.item)) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            } footer: {
                FooterText("Click to add or remove, or drag onto the notch (up to \(LiveActivities.perSide) a side). Click one beside the notch to use it (play/pause, pause the timer, join the meeting…), hold it to open its details, or right-click for its options.")
            }
            Section {
                Picker(selection: $settings.glanceDensity) {
                    ForEach(GlanceDensity.allCases) { Text($0.label).tag($0) }
                } label: {
                    RowLabel(title: "Density", subtitle: "How close together they sit.")
                }
                .pickerStyle(.segmented)
            } footer: {
                FooterText("When a side runs out of room on a smaller screen, the Glances farthest from the notch turn compact, then fold into a “+” you can click.")
            }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
        // A tile being dragged floats above everything, following the pointer.
        .overlay(alignment: .topLeading) {
            if let item = gallery.item {
                GalleryDragPill(item: item, landing: gallery.target != nil)
                    .position(x: gallery.location.x - origin.x, y: gallery.location.y - origin.y)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { live.previewing = true }
        .onDisappear { live.previewing = false }
    }
}

/// Where a dragged activity would land beside the notch.
struct StageTarget: Equatable {
    var side: LiveSlot.Side
    var index: Int
}

/// A gallery tile being dragged toward the notch, shared by the gallery, the stage and the pane.
/// `location` is in global (window) coordinates.
@MainActor
final class GalleryDrag: ObservableObject {
    @Published var item: LiveItem?
    @Published var location: CGPoint = .zero
    @Published var target: StageTarget?
}

/// The floating pill under the pointer while a gallery tile is dragged.
private struct GalleryDragPill: View {
    let item: LiveItem
    let landing: Bool
    @ObservedObject private var live = LiveActivities.shared

    var body: some View {
        Group {
            if live.hasReading(item) {
                LiveItemView(item: item, notchHeight: 32)
                    .frame(width: item.width(notchHeight: 32), height: 32)
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.tint)
                    .frame(width: 40, height: 32)
            }
        }
        .padding(.horizontal, 12)
        .background(Capsule().fill(.black))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .scaleEffect(landing ? 1.08 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: landing)
        .environment(\.colorScheme, .dark)
        .environmentObject(AppSettings.shared)
        .environmentObject(MediaController.shared)
        .environmentObject(BatteryMonitor.shared)
        .environmentObject(TaskStore.shared)
        .environmentObject(SystemMonitor.shared)
        .environmentObject(CalendarManager.shared)
        .environmentObject(TimerStore.shared)
    }
}

/// The notch, drawn big on a dark desktop, laid out exactly like the real one. Activities are
/// dragged with a plain gesture (not system drag and drop), so the rest reflow live around a gap.
private struct NotchStage: View {
    @ObservedObject var gallery: GalleryDrag
    @ObservedObject private var live = LiveActivities.shared
    @State private var width: CGFloat = 540
    /// The stage's frame in global coordinates, for gallery drags.
    @State private var frame: CGRect = .zero
    @State private var drag: Drag?
    @State private var selected: LiveItem?
    @State private var hovered: LiveItem?

    private struct Drag {
        var item: LiveItem
        var location: CGPoint
        var grab: CGSize
        var target: StageTarget?
    }

    /// One activity's place: its center x in the stage, and width, both already scaled.
    private struct Placed: Identifiable {
        let item: LiveItem
        let x: CGFloat
        let width: CGFloat
        var id: LiveItem { item }
    }

    private struct Layout {
        var placed: [Placed] = []
        var notchWidth: CGFloat = 0
    }

    private let base = CGSize(width: 180, height: 32)
    private let height: CGFloat = 190

    /// Scale: as big as fits, up to 1.7× real size. Follows what's pinned, not the drag, so it holds still.
    private var scale: CGFloat {
        let side = sideWidth(live.items(on: .left).map(\.item), live.items(on: .right).map(\.item))
        return min(1.7, max(0.6, (width - 150) / (base.width + 2 * side)))
    }
    private var center: CGFloat { width / 2 }
    private var notchHeight: CGFloat { base.height * scale }

    /// The drag shaping the layout: one on the stage, or a gallery tile over the notch.
    private var activeDrag: Drag? {
        if let drag { return drag }
        guard let item = gallery.item, let target = gallery.target else { return nil }
        return Drag(item: item, location: .zero, grab: .zero, target: target)
    }

    var body: some View {
        let current = layout(including: activeDrag)
        let drag = activeDrag
        ZStack(alignment: .topLeading) {
            backdrop
            // The notch.
            NotchShape(topRadius: 8 * scale, bottomRadius: 14 * scale)
                .fill(.black)
                .frame(width: current.notchWidth, height: notchHeight)
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                .position(x: center, y: notchHeight / 2)
            // Camera.
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.2), Color(white: 0.04)], center: .center, startRadius: 0, endRadius: 5 * scale))
                .frame(width: 8 * scale, height: 8 * scale)
                .position(x: center, y: notchHeight / 2)
            // The gap a dragged activity will drop into.
            if let drag, drag.target != nil, let slot = current.placed.first(where: { $0.item == drag.item }) {
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .frame(width: slot.width + 8 * scale, height: notchHeight - 8 * scale)
                    .position(x: slot.x, y: notchHeight / 2)
            }
            // Every pinned activity stays in the view tree while one is dragged (it's hidden), or its
            // gesture would be cancelled when it leaves the layout over the remove zone.
            let resting = layout(including: nil)
            ForEach(live.slots) { slot in
                if let placed = current.placed.first(where: { $0.item == slot.item })
                    ?? resting.placed.first(where: { $0.item == slot.item }) {
                    chip(placed).opacity(drag?.item == slot.item ? 0 : 1)
                }
            }
            if let drag = self.drag { floating(drag) }
            overlayText
            if self.drag != nil { removeZone }
            if drag == nil, gallery.item == nil, let removal = live.lastRemoval { undoToast(removal) }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: "stage")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0; width = max($0.width, 200) }
        .onChange(of: gallery.location) { _, location in
            guard let item = gallery.item else { return }
            let point = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
            let target = frame.contains(location) ? target(at: point, for: item, anywhere: true) : nil
            if gallery.target != target { gallery.target = target }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(gallery.target != nil ? 0.9 : 0), lineWidth: 2)
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: live.slots)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: drag?.target)
        .animation(.easeOut(duration: 0.18), value: self.drag == nil)
        .animation(.easeOut(duration: 0.15), value: gallery.item == nil)
        .animation(.easeOut(duration: 0.2), value: live.lastRemoval)
        .environment(\.colorScheme, .dark)
        .environmentObject(AppSettings.shared)
        .environmentObject(MediaController.shared)
        .environmentObject(BatteryMonitor.shared)
        .environmentObject(TaskStore.shared)
        .environmentObject(SystemMonitor.shared)
        .environmentObject(CalendarManager.shared)
        .environmentObject(TimerStore.shared)
    }

    // MARK: Pieces

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), Color(red: 0.12, green: 0.1, blue: 0.2)],
                           startPoint: .top, endPoint: .bottom)
            // A soft glow under the notch.
            RadialGradient(colors: [Color.accentColor.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: 260)
                .offset(y: notchHeight)
            // A faint menu bar, so it reads as the top of the screen.
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "apple.logo")
                    Spacer()
                    Text(Date().formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                }
                .font(.system(size: 11 * min(scale, 1.2), weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 16)
                .frame(height: notchHeight)
                .background(.white.opacity(0.04))
                Spacer()
            }
        }
    }

    private func chip(_ placed: Placed) -> some View {
        let item = placed.item
        return content(item)
            .frame(width: placed.width, height: notchHeight)
            .background(
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(.white.opacity(selected == item ? 0.16 : hovered == item ? 0.09 : 0))
                    .padding(.vertical, 4 * scale).padding(.horizontal, -5 * scale)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovered = inside ? item : (hovered == item ? nil : hovered)
                guard drag == nil else { return }
                (inside ? NSCursor.openHand : NSCursor.arrow).set()
            }
            .onTapGesture { selected = item }
            .gesture(dragGesture(for: placed))
            .popover(isPresented: Binding(get: { selected == item }, set: { if !$0 { selected = nil } }), arrowEdge: .bottom) {
                ActivityOptions(item: item) { selected = nil }
            }
            .help(item.title)
            .position(x: placed.x, y: notchHeight / 2)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    /// The activity under the pointer while it's dragged: lifted, and following the pointer exactly.
    private func floating(_ drag: Drag) -> some View {
        let removing = drag.target == nil
        return content(drag.item)
            .frame(width: drag.item.width(notchHeight: base.height) * scale, height: notchHeight)
            .padding(.horizontal, 8 * scale)
            .background(Capsule().fill(.black))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
            .scaleEffect(removing ? 0.85 : 1.06)
            .opacity(removing ? 0.7 : 1)
            .position(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
            .allowsHitTesting(false)
            .transaction { $0.animation = nil }
    }

    /// A pinned activity at the stage's scale: its live reading, or its icon, faint, while waiting.
    private func content(_ item: LiveItem) -> some View {
        Group {
            if live.isShowingNow(item) {
                LiveItemView(item: item, notchHeight: base.height, compact: live.slot(for: item)?.compact ?? false)
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.tint.opacity(0.5))
            }
        }
        .frame(width: live.width(item, notchHeight: base.height), height: base.height)
        .scaleEffect(scale)
    }

    @ViewBuilder private var overlayText: some View {
        Group {
            if live.slots.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing beside the notch yet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("Pick activities below to keep them here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .position(x: center, y: height / 2 + 14)
            } else if gallery.item != nil {
                Text(gallery.target == nil ? "Drop beside the notch to add" : "Release to add")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .position(x: center, y: height - 22)
            } else if drag == nil, live.lastRemoval != nil {
                EmptyView()
            } else if drag == nil {
                Text("Drag to rearrange  ·  Click for options  ·  Drag down to remove")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .position(x: center, y: height - 22)
            }
        }
        .allowsHitTesting(false)
    }

    private func undoToast(_ removal: LiveActivities.Removal) -> some View {
        HStack(spacing: 10) {
            Text(removal.message).foregroundStyle(.white.opacity(0.85))
            Button("Undo") { live.undoRemoval() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .keyboardShortcut("z", modifiers: .command)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .position(x: center, y: height - 30)
        .transition(.opacity.combined(with: .offset(y: 8)))
        .id(removal.id)
    }

    private var removeZone: some View {
        let active = drag?.target == nil
        return HStack(spacing: 6) {
            Image(systemName: "trash")
            Text("Remove")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(active ? .white : .white.opacity(0.55))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(active ? Color.red.opacity(0.85) : .white.opacity(0.08)))
        .scaleEffect(active ? 1.08 : 1)
        .position(x: center, y: height - 30)
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .offset(y: 10)))
    }

    // MARK: Layout & dragging

    private func sideWidth(_ left: [LiveItem], _ right: [LiveItem]) -> CGFloat {
        [left, right].map { items -> CGFloat in
            guard !items.isEmpty else { return 0 }
            return items.reduce(0) { $0 + live.width($1, notchHeight: base.height) } + CGFloat(items.count - 1) * LiveActivities.spacing
                + LiveActivities.outerPadding + LiveActivities.innerPadding
        }.max() ?? 0
    }

    /// Where everything sits, like the real notch: each side's activities hug its outer edge.
    /// A dragged activity is taken out, and put back at its target to make the gap.
    private func layout(including drag: Drag?) -> Layout {
        var left = live.items(on: .left).map(\.item)
        var right = live.items(on: .right).map(\.item)
        if let drag {
            left.removeAll { $0 == drag.item }
            right.removeAll { $0 == drag.item }
            if let t = drag.target {
                if t.side == .left { left.insert(drag.item, at: min(t.index, left.count)) }
                else { right.insert(drag.item, at: min(t.index, right.count)) }
            }
        }
        let side = sideWidth(left, right) * scale
        let half = base.width * scale / 2
        let gap = LiveActivities.spacing * scale
        let outer = LiveActivities.outerPadding * scale
        var placed: [Placed] = []
        var x = center - half - side + outer
        for item in left {
            let w = live.width(item, notchHeight: base.height) * scale
            placed.append(Placed(item: item, x: x + w / 2, width: w))
            x += w + gap
        }
        let rightTotal = right.reduce(0) { $0 + live.width($1, notchHeight: base.height) * scale } + CGFloat(max(right.count - 1, 0)) * gap
        x = center + half + side - outer - rightTotal
        for item in right {
            let w = live.width(item, notchHeight: base.height) * scale
            placed.append(Placed(item: item, x: x + w / 2, width: w))
            x += w + gap
        }
        return Layout(placed: placed, notchWidth: base.width * scale + 2 * side)
    }

    /// Which side and place a point would drop at, judged against the layout without the dragged
    /// activity (so the gap opening up doesn't move the target back and forth).
    private func target(at point: CGPoint, for item: LiveItem, anywhere: Bool = false) -> StageTarget? {
        guard anywhere || point.y < notchHeight + 70 else { return nil }
        let side: LiveSlot.Side = point.x < center ? .left : .right
        let others = layout(including: Drag(item: item, location: .zero, grab: .zero, target: nil)).placed
        let onSide = others.filter { live.slot(for: $0.item)?.side == side }
        return StageTarget(side: side, index: onSide.filter { $0.x < point.x }.count)
    }

    private func dragGesture(for placed: Placed) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("stage"))
            .onChanged { value in
                if drag == nil {
                    selected = nil
                    NSCursor.closedHand.set()
                    drag = Drag(item: placed.item, location: value.startLocation,
                                grab: CGSize(width: value.startLocation.x - placed.x, height: value.startLocation.y - notchHeight / 2))
                }
                drag?.location = value.location
                let point = CGPoint(x: value.location.x - (drag?.grab.width ?? 0), y: value.location.y)
                drag?.target = target(at: point, for: placed.item)
            }
            .onEnded { _ in
                NSCursor.arrow.set()
                guard let drag else { return }
                if let t = drag.target {
                    live.place(drag.item, side: t.side, at: t.index)
                } else {
                    live.remove([drag.item])
                }
                self.drag = nil
            }
    }
}

/// A pinned activity's options, in a popover from the stage.
private struct ActivityOptions: View {
    let item: LiveItem
    let close: () -> Void
    @ObservedObject private var live = LiveActivities.shared

    var body: some View {
        if let slot = live.slot(for: item) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ItemTile(item: item, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 13, weight: .semibold))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Side").foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { slot.side }, set: { side in
                            live.place(item, side: side, at: side == .left ? live.items(on: .left).count : 0)
                        })) {
                            Text("Left").tag(LiveSlot.Side.left)
                            Text("Right").tag(LiveSlot.Side.right)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { slot.compact }, set: { on in live.update(item) { $0.compact = on } })) {
                            Text("Regular").tag(false)
                            Text("Compact").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if item.canWaitForActivity {
                        GridRow {
                            Text("Show").foregroundStyle(.secondary)
                            Picker("", selection: Binding(get: { slot.whileActive },
                                                          set: { on in live.update(item) { $0.whileActive = on } })) {
                                Text("Always").tag(false)
                                Text(item.whileActiveLabel).tag(true)
                            }
                            .labelsHidden()
                        }
                    }
                }
                .font(.system(size: 12))
                Button(role: .destructive) {
                    close()
                    live.remove([item])
                } label: {
                    Text("Remove from Notch").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.delete, modifiers: [])
                .controlSize(.large)
            }
            .padding(16)
            .frame(width: 290)
        }
    }
}

/// Every activity as a tile with a little notch pill showing its reading. Click to toggle, or drag
/// one onto the notch to put it in a particular place.
private struct ActivityGallery: View {
    @ObservedObject var gallery: GalleryDrag
    @ObservedObject private var live = LiveActivities.shared

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], spacing: 10) {
            ForEach(LiveItem.allCases) { item in
                GalleryTile(item: item, pinned: live.slot(for: item) != nil, gallery: gallery) {
                    if live.slot(for: item) != nil {
                        live.remove([item])
                    } else {
                        let side: LiveSlot.Side = live.items(on: .left).count <= live.items(on: .right).count ? .left : .right
                        live.place(item, side: side, at: side == .left ? live.items(on: .left).count : 0)
                    }
                }
            }
        }
    }
}

private struct GalleryTile: View {
    let item: LiveItem
    let pinned: Bool
    @ObservedObject var gallery: GalleryDrag
    let toggle: () -> Void
    @ObservedObject private var live = LiveActivities.shared
    @State private var hovering = false

    private var dragged: Bool { gallery.item == item }

    var body: some View {
        VStack(spacing: 9) {
            // What it looks like in the notch.
            Group {
                if live.hasReading(item) {
                    LiveItemView(item: item, notchHeight: 30)
                        .frame(width: item.width(notchHeight: 30), height: 30)
                        .environment(\.colorScheme, .dark)
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.tint)
                }
            }
            .frame(width: 84, height: 30)
            .background(Capsule().fill(.black))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            Text(item.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(pinned ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(pinned ? Color.accentColor.opacity(0.12) : Color.primary.opacity(hovering ? 0.07 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(pinned ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.06), lineWidth: pinned ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            Image(systemName: pinned ? "checkmark.circle.fill" : "plus.circle.fill")
                .font(.system(size: 14))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, pinned ? Color.accentColor : Color.secondary.opacity(0.6))
                .opacity(pinned || hovering ? 1 : 0)
                .padding(6)
        }
        .scaleEffect(hovering && !dragged ? 1.02 : 1)
        .opacity(dragged ? 0.4 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { inside in
            hovering = inside
            guard gallery.item == nil else { return }
            (inside ? NSCursor.openHand : NSCursor.arrow).set()
        }
        .onTapGesture(perform: toggle)
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    if gallery.item == nil {
                        gallery.item = item
                        NSCursor.closedHand.set()
                    }
                    gallery.location = value.location
                }
                .onEnded { _ in
                    if let target = gallery.target {
                        live.place(item, side: target.side, at: target.index)
                    }
                    gallery.item = nil
                    gallery.target = nil
                    NSCursor.arrow.set()
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(pinned ? "Beside the notch" : "Not added")
        .accessibilityAction { toggle() }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pinned)
        .help(item.detail)
        .environmentObject(AppSettings.shared)
        .environmentObject(MediaController.shared)
        .environmentObject(BatteryMonitor.shared)
        .environmentObject(TaskStore.shared)
        .environmentObject(SystemMonitor.shared)
        .environmentObject(CalendarManager.shared)
        .environmentObject(TimerStore.shared)
    }
}

private struct ItemTile: View {
    let item: LiveItem
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: item.icon)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [item.tint.opacity(0.95), item.tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            )
    }
}
