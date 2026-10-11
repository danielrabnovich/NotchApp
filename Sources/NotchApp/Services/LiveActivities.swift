import Combine
import EventKit
import SwiftUI

/// Something that can stay on beside the closed notch.
enum LiveItem: String, CaseIterable, Codable, Identifiable {
    case music, timer, cpu, temperature, memory, gpu, power, battery, nextEvent, tasks, network, devices, privacy, agents, vpn, keepAwake, disk
    /// A call in progress: its time and the mic's state (click to mute).
    case meeting
    /// Anything downloading, copying, converting or exporting: a ring and percent.
    case progress
    case worldClock, weather, goldenHour, unread, countdown
    /// Actions: a button beside the notch rather than a reading.
    case askScreen, quickScreenshot, quickCopyText, quickColorPicker, quickLock, quickDarkMode, quickMic, quickWiFi, quickNightShift
    /// The actions starred for the app in front (right-click one under the search bar).
    case appAction

    var id: String { rawValue }

    static let actions: [LiveItem] = [.appAction, .askScreen, .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock,
                                      .quickDarkMode, .quickMic, .quickWiFi, .quickNightShift]
    static let readings: [LiveItem] = allCases.filter { !actions.contains($0) }
    var isAction: Bool { Self.actions.contains(self) }

    /// The Controls tile the action shares its behaviour with.
    var controlAction: ControlAction? {
        switch self {
        case .quickScreenshot: .screenshot
        case .quickCopyText: .copyText
        case .quickColorPicker: .colorPicker
        case .quickLock: .lockScreen
        case .quickDarkMode: .darkMode
        case .quickMic: .mic
        case .quickWiFi: .wifi
        case .quickNightShift: .nightShift
        default: nil
        }
    }

    var title: String {
        switch self {
        case .music: "Now Playing"
        case .timer: "Timer"
        case .cpu: "CPU"
        case .temperature: "Temperature"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .power: "Power"
        case .battery: "Battery"
        case .nextEvent: "Next Event"
        case .tasks: "Tasks"
        case .network: "Network"
        case .devices: "Bluetooth Battery"
        case .privacy: "Mic & Camera"
        case .agents: "Agents"
        case .vpn: "VPN"
        case .keepAwake: "Keep Awake"
        case .disk: "Disk Space"
        case .meeting: "Meeting"
        case .progress: "Progress"
        case .worldClock: "World Clock"
        case .weather: "Weather"
        case .goldenHour: "Golden Hour"
        case .unread: "Unread"
        case .countdown: "Countdown"
        case .askScreen: "Ask About This"
        case .appAction: "App Actions"
        case .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock, .quickDarkMode, .quickMic, .quickWiFi, .quickNightShift: controlAction!.title
        }
    }

    var detail: String {
        switch self {
        case .music: "Cover art and a visualizer."
        case .timer: "Progress ring and time left."
        case .cpu: "How busy the processor is."
        case .temperature: "CPU temperature, warmer colors as it heats up."
        case .memory: "How much memory is in use."
        case .gpu: "How busy the graphics are."
        case .power: "What the whole Mac is drawing, in watts."
        case .battery: "Charge level."
        case .nextEvent: "Countdown to your next meeting."
        case .tasks: "How many tasks are open."
        case .network: "Download speed right now."
        case .devices: "The emptiest connected AirPods, mouse or keyboard."
        case .privacy: "A dot while an app uses the microphone or camera."
        case .agents: "Coding agents at work, and a hand when one needs you."
        case .vpn: "A shield and the country your traffic exits in."
        case .keepAwake: "A cup while the Mac is being kept awake, with time left."
        case .disk: "Free space on the startup disk."
        case .meeting: "During a call: how long it's been, and a mute button."
        case .progress: "Downloads, copies, conversions and exports from Final Cut, HandBrake and more."
        case .worldClock: "The time in another city you pick."
        case .weather: "The temperature and sky outside now."
        case .goldenHour: "Time until golden hour before sunset, for the best light."
        case .unread: "Unread counts from Slack, Discord, Mail and the rest of your Dock, in one place."
        case .countdown: "Days until a date you set: a launch, a trip, a deadline."
        case .askScreen: "Ask the AI about the window in front."
        case .appAction: "Actions you star for an app (right-click one under the search bar), while that app is in front."
        case .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock, .quickDarkMode, .quickMic, .quickWiFi, .quickNightShift: controlAction!.detail
        }
    }

    var icon: String {
        switch self {
        case .music: "music.note"
        case .timer: "timer"
        case .cpu: "cpu"
        case .temperature: "thermometer.medium"
        case .memory: "memorychip"
        case .gpu: "square.stack.3d.up.fill"
        case .power: "bolt.fill"
        case .battery: "battery.75percent"
        case .nextEvent: "calendar"
        case .tasks: "checklist"
        case .network: "arrow.up.arrow.down"
        case .devices: "airpods"
        case .privacy: "mic.fill"
        case .agents: "sparkles.rectangle.stack.fill"
        case .vpn: "lock.shield.fill"
        case .keepAwake: "cup.and.saucer.fill"
        case .disk: "internaldrive.fill"
        case .meeting: "phone.fill"
        case .progress: "circle.dashed"
        case .worldClock: "globe"
        case .weather: "cloud.sun.fill"
        case .goldenHour: "sun.horizon.fill"
        case .unread: "bubble.left.and.bubble.right.fill"
        case .countdown: "flag.checkered"
        case .askScreen: "sparkle.magnifyingglass"
        case .appAction: "star.square.on.square"
        case .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock, .quickDarkMode, .quickMic, .quickWiFi, .quickNightShift: controlAction!.icon
        }
    }

    var tint: Color {
        switch self {
        case .music: .pink
        case .timer: TimerPalette.accent
        case .cpu: .cyan
        case .temperature: .orange
        case .memory: .purple
        case .gpu: .mint
        case .power: .yellow
        case .battery: .green
        case .nextEvent: .red
        case .tasks: .teal
        case .network: .blue
        case .devices: .indigo
        case .privacy: .orange
        case .agents: .purple
        case .vpn: .green
        case .keepAwake: .brown
        case .disk: .pink
        case .meeting: .green
        case .progress: .blue
        case .worldClock: .teal
        case .weather: .cyan
        case .goldenHour: .orange
        case .unread: .red
        case .countdown: .purple
        case .askScreen: .indigo
        case .appAction: .orange
        case .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock, .quickDarkMode, .quickMic, .quickWiFi, .quickNightShift: controlAction!.tint
        }
    }

    /// Items that come and go: these can be shown only while there's something to show.
    var canWaitForActivity: Bool { [.music, .timer, .nextEvent, .network, .devices, .agents, .vpn, .disk, .goldenHour, .unread].contains(self) }

    var whileActiveLabel: String {
        switch self {
        case .music: "Only while playing"
        case .timer: "Only while running"
        case .nextEvent: "Only within the hour"
        case .network: "Only while busy"
        case .devices: "Only when low"
        case .agents: "Only while working"
        case .vpn: "Only while connected"
        case .disk: "Only when low"
        case .meeting: "Only during calls"
        case .progress: "Only while something runs"
        case .goldenHour: "Only near sunset"
        case .unread: "Only with something unread"
        default: ""
        }
    }

    /// Fixed widths, so values ticking over never resize the notch.
    func width(notchHeight h: CGFloat, compact: Bool = false) -> CGFloat {
        if compact { return compactWidth(notchHeight: h) }
        return switch self {
        case .music: h + 12
        case .timer: 64
        case .cpu, .gpu, .memory: 50
        case .temperature: 46
        case .power: 52
        case .battery: 68
        case .nextEvent: 62
        case .tasks: 22
        case .network: 60
        case .devices: 58
        case .privacy: 34
        case .agents: 40
        case .vpn: 50
        case .keepAwake: 52
        case .disk: 58
        case .meeting: 72
        case .progress: 54
        case .worldClock: 76
        case .weather: 50
        case .goldenHour: 66
        case .unread: 52
        case .countdown: 56
        case .askScreen, .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock, .quickDarkMode, .quickMic, .quickWiFi, .quickNightShift: 24
        case .appAction: CGFloat(max(1, AppActions.glanceCount)) * 24
        }
    }

    /// The compact form: just the reading, a small gauge, or the glyph.
    private func compactWidth(notchHeight h: CGFloat) -> CGFloat {
        switch self {
        case .music: h - 10
        case .timer: 40
        case .cpu, .gpu, .memory: 20
        case .temperature: 28
        case .power: 30
        case .battery: BatteryGlyph.width() + 2
        case .nextEvent: 40
        case .tasks: 22
        case .network: 40
        case .devices, .privacy, .agents, .vpn, .keepAwake: 20
        case .disk: 32
        case .meeting: 46
        case .progress: 22
        case .worldClock: 40
        case .weather: 32
        case .goldenHour: 40
        case .unread: 26
        case .countdown: 30
        case .askScreen, .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock, .quickDarkMode, .quickMic, .quickWiFi, .quickNightShift: 24
        case .appAction: CGFloat(max(1, AppActions.glanceCount)) * 24
        }
    }

    var usesStats: Bool { [.cpu, .temperature, .memory, .gpu, .power].contains(self) }
}

struct LiveSlot: Codable, Identifiable, Equatable {
    enum Side: String, Codable, CaseIterable { case left, right }

    var item: LiveItem
    var side: Side
    var whileActive: Bool
    /// Always shown in its compact form (it may also turn compact by itself when a side is full).
    var compact = false
    var id: LiveItem { item }

    init(item: LiveItem, side: Side, whileActive: Bool, compact: Bool = false) {
        self.item = item
        self.side = side
        self.whileActive = whileActive
        self.compact = compact
    }

    // Saved layouts from before `compact` existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(LiveItem.self, forKey: .item)
        side = try c.decode(Side.self, forKey: .side)
        whileActive = try c.decode(Bool.self, forKey: .whileActive)
        compact = try c.decodeIfPresent(Bool.self, forKey: .compact) ?? false
    }
}

/// How tightly Glances sit beside each other.
enum GlanceDensity: String, CaseIterable, Identifiable {
    case roomy, regular, tight
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var spacing: CGFloat {
        switch self {
        case .roomy: 14
        case .regular: 10
        case .tight: 6
        }
    }
}

/// One side as drawn: each Glance and whether it's compact, plus how many didn't fit.
struct GlanceRow: Equatable {
    var items: [(item: LiveItem, compact: Bool)] = []
    var overflow = 0
    var width: CGFloat = 0

    static func == (a: GlanceRow, b: GlanceRow) -> Bool {
        a.overflow == b.overflow && a.width == b.width
            && a.items.map(\.item) == b.items.map(\.item) && a.items.map(\.compact) == b.items.map(\.compact)
    }
}

/// The live activities pinned beside the closed notch, which of them are showing right now, and
/// how wide that makes each side. Quick alerts (volume, charging…) still take over while they show.
@MainActor
final class LiveActivities: ObservableObject {
    static let shared = LiveActivities()

    /// Pinned items, in order. Saved.
    @Published var slots: [LiveSlot] {
        didSet {
            if let data = try? JSONEncoder().encode(slots) { UserDefaults.standard.set(data, forKey: "liveActivities") }
            recompute()
        }
    }

    /// What's showing on each side right now.
    @Published private(set) var left: [LiveItem] = []
    @Published private(set) var right: [LiveItem] = []

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let saved = UserDefaults.standard.data(forKey: "liveActivities")
        slots = saved.flatMap { try? JSONDecoder().decode([LiveSlot].self, from: $0) } ?? []
    }

    var isEmpty: Bool { left.isEmpty && right.isEmpty }

    func start() {
        let media = MediaController.shared, timer = TimerStore.shared, battery = BatteryMonitor.shared
        let refresh: () -> Void = { [weak self] in DispatchQueue.main.async { self?.recompute() } }
        media.$isPlaying.sink { _ in refresh() }.store(in: &cancellables)
        media.$title.sink { _ in refresh() }.store(in: &cancellables)
        timer.$state.sink { _ in refresh() }.store(in: &cancellables)
        battery.$hasBattery.sink { _ in refresh() }.store(in: &cancellables)
        CalendarManager.shared.$events.sink { _ in refresh() }.store(in: &cancellables)
        TaskStore.shared.objectWillChange.sink { _ in refresh() }.store(in: &cancellables)
        DeviceBatteries.shared.$devices.sink { _ in refresh() }.store(in: &cancellables)
        PrivacyMonitor.shared.objectWillChange.sink { _ in refresh() }.store(in: &cancellables)
        AgentMonitor.shared.$sessions.sink { _ in refresh() }.store(in: &cancellables)
        VPNMonitor.shared.$connections.sink { _ in refresh() }.store(in: &cancellables)
        KeepAwake.shared.$isActive.sink { _ in refresh() }.store(in: &cancellables)
        AppActions.shared.$glanceActions.sink { _ in refresh() }.store(in: &cancellables)
        MeetingMonitor.shared.$call.sink { _ in refresh() }.store(in: &cancellables)
        ProgressCenter.shared.$items.sink { _ in refresh() }.store(in: &cancellables)
        UnreadBadges.shared.$badges.sink { _ in refresh() }.store(in: &cancellables)
        TodayWeather.shared.$report.sink { _ in refresh() }.store(in: &cancellables)
        Cleaner.shared.$disk.sink { _ in refresh() }.store(in: &cancellables)
        // Network "only while busy" follows the rate, which changes every second.
        NetworkMonitor.shared.$downRate.sink { _ in
            if LiveActivities.shared.slot(for: .network)?.whileActive == true { refresh() }
        }.store(in: &cancellables)
        // "Within the hour" and a reading appearing (temperature) change with time, not events.
        Timer.publish(every: 20, on: .main, in: .common).autoconnect().sink { _ in refresh() }.store(in: &cancellables)
        recompute()
    }

    func slot(for item: LiveItem) -> LiveSlot? { slots.first { $0.item == item } }

    /// Most Glances a side holds.
    static let perSide = 5

    func isFull(_ side: LiveSlot.Side) -> Bool { items(on: side).count >= Self.perSide }

    func pin(_ item: LiveItem) {
        guard slot(for: item) == nil else { return }
        // Alternate sides so a first few picks balance out.
        var side: LiveSlot.Side = slots.filter { $0.side == .left }.count <= slots.filter { $0.side == .right }.count ? .left : .right
        if isFull(side) { side = side == .left ? .right : .left }
        guard !isFull(side) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            slots.append(LiveSlot(item: item, side: side, whileActive: item.canWaitForActivity))
        }
    }

    func unpin(_ item: LiveItem) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { slots.removeAll { $0.item == item } }
    }

    /// The last removal made in Settings, kept for a few seconds so it can be undone.
    struct Removal: Equatable {
        let id = UUID()
        let message: String
        let slots: [LiveSlot]
    }
    @Published private(set) var lastRemoval: Removal?

    /// Removes activities from Settings, offering an undo.
    func remove(_ items: [LiveItem]) {
        let removing = slots.filter { items.contains($0.item) }
        guard !removing.isEmpty else { return }
        let removal = Removal(message: removing.count == 1 ? "Removed \(removing[0].item.title)" : "Removed \(removing.count) activities",
                              slots: slots)
        lastRemoval = removal
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { slots.removeAll { items.contains($0.item) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.lastRemoval == removal { self?.lastRemoval = nil }
        }
    }

    func undoRemoval() {
        guard let removal = lastRemoval else { return }
        lastRemoval = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { slots = removal.slots }
    }

    func update(_ item: LiveItem, _ change: (inout LiveSlot) -> Void) {
        guard let i = slots.firstIndex(where: { $0.item == item }) else { return }
        var slot = slots[i]
        change(&slot)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { slots[i] = slot }
    }

    /// The pinned items on one side, left to right as drawn.
    func items(on side: LiveSlot.Side) -> [LiveSlot] { slots.filter { $0.side == side } }

    /// Pins (or moves) an item to a position on a side; `index` counts left to right as drawn.
    func place(_ item: LiveItem, side: LiveSlot.Side, at index: Int) {
        var slot = slot(for: item) ?? LiveSlot(item: item, side: side, whileActive: item.canWaitForActivity)
        // A full side takes no more (moving within it is fine).
        if slot.side != side || self.slot(for: item) == nil, isFull(side) { return }
        slot.side = side
        var left = slots.filter { $0.side == .left && $0.item != item }
        var right = slots.filter { $0.side == .right && $0.item != item }
        if side == .left {
            left.insert(slot, at: min(max(index, 0), left.count))
        } else {
            right.insert(slot, at: min(max(index, 0), right.count))
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { slots = left + right }
    }

    /// Whether a pinned item has something to show right now (for dimming it in the editor).
    func isShowingNow(_ item: LiveItem) -> Bool { slot(for: item).map(isShowing) ?? false }

    /// Whether an item, pinned or not, has a reading to preview (as if set to show always).
    func hasReading(_ item: LiveItem) -> Bool {
        isShowing(slot(for: item) ?? LiveSlot(item: item, side: .left, whileActive: false))
    }

    /// While the Live Activities settings are open, every reading is kept fresh for the gallery.
    var previewing = false { didSet { if previewing != oldValue { recompute() } } }

    func move(from source: IndexSet, to destination: Int) {
        slots.move(fromOffsets: source, toOffset: destination)
    }

    /// Width of each side of the notch: the fuller side decides, so the notch stays centered.
    func sideWidth(notchHeight h: CGFloat, budget: CGFloat) -> CGFloat {
        max(row(.left, notchHeight: h, budget: budget).width, row(.right, notchHeight: h, budget: budget).width)
    }

    /// One side laid out within `budget` points. Glances farther from the notch give way first:
    /// they turn compact, then fold into a "+N" — they're also the ones that would cover the
    /// menu bar's menus and icons.
    func row(_ side: LiveSlot.Side, notchHeight h: CGFloat, budget: CGFloat) -> GlanceRow {
        // Nearest the notch first (the left side is drawn outside-in).
        let near = side == .left ? Array(left.reversed()) : right
        guard !near.isEmpty else { return GlanceRow() }
        let spacing = AppSettings.shared.glanceDensity.spacing
        var compact = near.map { slot(for: $0)?.compact ?? false }
        var count = near.count
        func width() -> CGFloat {
            let items = (0..<count).reduce(CGFloat(0)) { $0 + near[$1].width(notchHeight: h, compact: compact[$1]) }
            let more: CGFloat = count < near.count ? Self.overflowWidth + spacing : 0
            return items + CGFloat(count - 1) * spacing + more + Self.outerPadding + Self.innerPadding
        }
        // Compact from the outside in, then drop from the outside in (always keeping one).
        var i = count - 1
        while width() > budget, i >= 0 {
            compact[i] = true
            i -= 1
        }
        while width() > budget, count > 1 { count -= 1 }
        var row = GlanceRow(items: (0..<count).map { (near[$0], compact[$0]) }, overflow: near.count - count, width: width())
        if side == .left { row.items.reverse() }
        return row
    }

    static let overflowWidth: CGFloat = 20
    /// The gap between Glances, from the Density setting.
    static var spacing: CGFloat { AppSettings.shared.glanceDensity.spacing }

    /// A pinned Glance's width in the form it's set to (regular or compact).
    func width(_ item: LiveItem, notchHeight h: CGFloat) -> CGFloat {
        item.width(notchHeight: h, compact: slot(for: item)?.compact ?? false)
    }
    /// Room for the notch's rounded bottom corners on the outside, and a gap beside the hardware notch.
    static let outerPadding: CGFloat = 12
    static let innerPadding: CGFloat = 8

    /// Whether the stats sampler should keep values fresh for the notch.
    var wantsStats: Bool { slots.contains { $0.item.usesStats } }
    var wantsPrivacy: Bool { slot(for: .privacy) != nil }

    private func recompute() {
        let showing = slots.filter(isShowing)
        var newLeft = showing.filter { $0.side == .left }.map(\.item)
        var newRight = showing.filter { $0.side == .right }.map(\.item)
        // Once anything is pinned, the timer and music join the layout while they run (if their own
        // live activities are on) instead of replacing it: music at the left, the timer at the right.
        if !slots.isEmpty {
            let s = AppSettings.shared, media = MediaController.shared
            if slot(for: .music) == nil, s.musicEnabled, s.musicLiveActivity, media.hasTrack, media.isPlaying {
                newLeft.append(.music)
            }
            if slot(for: .timer) == nil, s.timerEnabled, s.timerLiveActivity, TimerStore.shared.isActive {
                newRight.append(.timer)
            }
        }
        // A call joins the left side by itself (meeting mode), pinned or not.
        if slot(for: .meeting) == nil, AppSettings.shared.meetingMode, MeetingMonitor.shared.call != nil {
            newLeft.append(.meeting)
        }
        // So does anything in progress, on the right.
        if slot(for: .progress) == nil, !ProgressCenter.shared.items.isEmpty {
            newRight.insert(.progress, at: 0)
        }
        if newLeft != left || newRight != right {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) {
                left = newLeft
                right = newRight
            }
        }
        SystemMonitor.shared.setLiveDemand(wantsStats || previewing)
        NetworkMonitor.shared.setLiveDemand(slot(for: .network) != nil || previewing)
        PrivacyMonitor.shared.setLiveDemand(wantsPrivacy || previewing)
        AgentMonitor.shared.setLiveDemand(slot(for: .agents) != nil || previewing)
        UnreadBadges.shared.setDemand(slot(for: .unread) != nil || previewing)
        // The weather (and the sun's times) for their Glances, kept within half an hour.
        if slot(for: .weather) != nil || slot(for: .goldenHour) != nil || previewing { TodayWeather.shared.refreshIfStale() }
    }

    private func isShowing(_ slot: LiveSlot) -> Bool {
        switch slot.item {
        case .music:
            let media = MediaController.shared
            return media.hasTrack && (media.isPlaying || !slot.whileActive)
        case .timer:
            return TimerStore.shared.isActive || !slot.whileActive
        case .nextEvent:
            guard let next = Self.nextEvent() else { return false }
            return !slot.whileActive || next.startDate.timeIntervalSinceNow <= 3600
        case .temperature:
            // Not every Mac reports one; don't hold a blank space for it.
            return SystemMonitor.shared.snapshot.cpuTemp != nil || SystemMonitor.shared.cpuHistory.isEmpty
        case .battery:
            return BatteryMonitor.shared.hasBattery
        case .tasks:
            return TaskStore.shared.openCount > 0
        case .cpu, .memory, .gpu:
            return true
        case .power:
            // Not every Mac reports it either.
            return SystemMonitor.shared.snapshot.systemPower != nil || SystemMonitor.shared.cpuHistory.isEmpty
        case .network:
            // "Busy" is more than background chatter: 200 KB/s either way.
            let n = NetworkMonitor.shared
            return !slot.whileActive || max(n.downRate, n.upRate) > 200_000
        case .devices:
            guard let level = DeviceBatteries.shared.lowest?.level else { return false }
            return !slot.whileActive || level <= 20
        case .privacy:
            return PrivacyMonitor.shared.isActive
        case .keepAwake:
            return KeepAwake.shared.isActive
        case .disk:
            guard let disk = Cleaner.shared.disk else { return false }
            return !slot.whileActive || disk.available < 20_000_000_000
        case .vpn:
            return !slot.whileActive || VPNMonitor.shared.connections.contains { $0.isUp && $0.fullTunnel }
        case .agents:
            guard AppSettings.shared.agentsEnabled else { return false }
            return !slot.whileActive || AgentMonitor.shared.activeCount > 0
        case .askScreen:
            return AppSettings.shared.assistantEnabled
        case .appAction:
            return !AppActions.shared.glanceActions.isEmpty
        case .meeting:
            return MeetingMonitor.shared.call != nil
        case .progress:
            return !ProgressCenter.shared.items.isEmpty
        case .worldClock, .countdown:
            return true
        case .weather:
            return TodayWeather.shared.report != nil
        case .goldenHour:
            guard let reading = GoldenHour.now() else { return false }
            return !slot.whileActive || reading.near || reading.golden
        case .unread:
            return !slot.whileActive || UnreadBadges.shared.total > 0
        case .quickNightShift:
            return NightShift.isAvailable
        case .quickScreenshot, .quickCopyText, .quickColorPicker, .quickLock, .quickDarkMode, .quickMic, .quickWiFi:
            return true
        }
    }

    /// The next timed event today that hasn't started yet.
    static func nextEvent(now: Date = Date()) -> EKEvent? {
        CalendarManager.shared.events.filter { !$0.isAllDay && $0.startDate > now }.min { $0.startDate < $1.startDate }
    }
}
