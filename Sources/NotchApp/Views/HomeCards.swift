import SwiftUI

/// A tile on Home: a column of the page like the others, only narrower (and half height when
/// small), with rules between. Under the pointer, a soft panel shows what a click would open.
struct HomeTile<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.06 : 0))
                    .padding(-6)
            )
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// The type every tile shares: a label for what it is, a figure (big when there's room), rows of a
/// list and their values, and a quieter detail line.
enum HomeType {
    static let label = Font.system(size: 10.5, weight: .medium)
    static let detail = Font.system(size: 10.5).monospacedDigit()
    static let row = Font.system(size: 11)
    static let value = Font.system(size: 11.5, weight: .semibold).monospacedDigit()
    static let figure = Font.system(size: 20, weight: .semibold).monospacedDigit()
    static let bigFigure = Font.system(size: 28, weight: .semibold).monospacedDigit()
    /// Labels and details.
    static let secondary = Color.white.opacity(0.55)
}

/// What a tile says with nothing to show: its symbol, and a word on why.
struct HomeNote: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))
            Text(text)
                .font(HomeType.label)
                .foregroundStyle(HomeType.secondary)
        }
        .frame(maxHeight: .infinity)
    }
}

/// How busy the Mac is: the Stats rings, and each one's number in its color. Small: the rings
/// beside the numbers and the power drawn; medium: the rings with the power and how hot it is, the
/// numbers under them, then the app working hardest.
struct StatsCard: View {
    var small = false
    @ObservedObject private var stats = SystemMonitor.shared
    @EnvironmentObject private var settings: AppSettings

    private struct Reading {
        let label: String
        let short: String
        let value: String
        let color: Color
    }

    var body: some View {
        let s = stats.snapshot
        let memory = s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : 0
        let percent = { (v: Double) in "\(Int((v * 100).rounded()))%" }
        let readings = [Reading(label: "CPU", short: "CPU", value: percent(s.cpuTotal), color: StatsPalette.cpu)]
            + (s.gpu.map { [Reading(label: "GPU", short: "GPU", value: percent($0), color: StatsPalette.gpu)] } ?? [])
            + [Reading(label: "Memory", short: "RAM", value: percent(memory), color: StatsPalette.memory)]
        let power = s.systemPower.map { Reading(label: "Power", short: "PWR", value: "\(formatSmall($0)) W", color: StatsPalette.power) }
        HomeTile {
            // Medium, unless Home's too short for it (a call bar above).
            ViewThatFits(in: .vertical) {
                if !small { medium(s, readings) }
                ForEach(power.map { [readings + [$0], readings] } ?? [readings], id: \.count) { rows in
                    HStack(spacing: 10) {
                        StatRings(diameter: 36)
                        numbers(rows, compact: true)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { NotchPresenter.shared.primary?.open(tab: .stats, takeKeyboard: false) }
        .help("Open Stats")
        .onAppear { stats.viewerAppeared() }
        .onDisappear { stats.viewerDisappeared() }
    }

    private func medium(_ s: SystemSnapshot, _ readings: [Reading]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                StatRings(diameter: 44)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    if let watts = s.systemPower {
                        HStack(spacing: 2) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(StatsPalette.power)
                            Text("\(formatSmall(watts)) W")
                                .rollingNumber(formatSmall(watts))
                        }
                        .font(HomeType.value)
                    }
                    if let celsius = s.cpuTemp {
                        // Only worth a color once it's running hot.
                        Text(settings.formatTemperature(celsius))
                            .font(HomeType.detail)
                            .foregroundStyle(celsius >= 80 ? StatsPalette.temperature(celsius) : HomeType.secondary)
                            .rollingNumber(settings.formatTemperature(celsius))
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            numbers(readings, compact: false)
            if let app = s.topCPU.first {
                HStack(spacing: 5) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath ?? "/System/Applications/Utilities/Activity Monitor.app"))
                        .resizable()
                        .frame(width: 13, height: 13)
                    Text(app.name)
                        .foregroundStyle(HomeType.secondary)
                    Spacer(minLength: 2)
                    // Of the whole Mac, like CPU above it (Activity Monitor's share of one core runs past 100%).
                    Text("\(Int((app.cpu / Double(max(1, s.cores.count)) * 100).rounded()))%")
                        .foregroundStyle(HomeType.secondary)
                }
                .font(HomeType.detail)
                .lineLimit(1)
                .padding(.top, 5)
                .help("Working hardest: \(app.name)")
            }
        }
        .onAppear { stats.detailAppeared() }
        .onDisappear { stats.detailDisappeared() }
    }

    /// Compact: the label in its color, shortened ("RAM"); otherwise a dot in its color.
    private func numbers(_ readings: [Reading], compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            ForEach(readings, id: \.label) { r in
                HStack(spacing: 5) {
                    if !compact { Circle().fill(r.color).frame(width: 6, height: 6) }
                    Text(compact ? r.short : r.label)
                        .font(compact ? .system(size: 9.5, weight: .medium) : HomeType.label)
                        .foregroundStyle(compact ? r.color : HomeType.secondary)
                    Spacer(minLength: 2)
                    Text(r.value)
                        .font(compact ? .system(size: 10.5, weight: .semibold).monospacedDigit() : HomeType.value)
                        .rollingNumber(r.value)
                }
                .lineLimit(1)
            }
        }
    }
}

/// The Mac's battery and the Bluetooth devices', emptiest first. Small: the two that matter
/// most; medium: up to five, with their names.
struct BatteriesCard: View {
    var small = false
    @EnvironmentObject private var battery: BatteryMonitor
    @ObservedObject private var devices = DeviceBatteries.shared

    private struct Row: Identifiable {
        let id: String
        let icon: String
        let name: String
        let level: Int
        var charging = false
    }

    private var rows: [Row] {
        let mac = battery.hasBattery
            ? [Row(id: "mac", icon: "laptopcomputer", name: "Mac", level: battery.level, charging: battery.isCharging)]
            : []
        let others = devices.devices.compactMap { d in d.level.map { Row(id: d.id, icon: d.icon, name: d.name, level: $0) } }
            .sorted { $0.level < $1.level }
        return mac + others
    }

    var body: some View {
        HomeTile {
            // As many as fit, up to two small or five medium.
            ViewThatFits(in: .vertical) {
                ForEach((1...(small ? 2 : 5)).reversed(), id: \.self) { count in
                    list(Array(rows.prefix(count)))
                }
            }
        }
    }

    private func list(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: small ? 4 : 5) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 18)
                    if small {
                        level(row)
                        Spacer(minLength: 0)
                    } else {
                        Text(row.name)
                            .font(HomeType.row)
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer(minLength: 4)
                        gauge(row)
                        level(row)
                    }
                }
                .lineLimit(1)
                .help("\(row.name): \(row.level)%")
            }
        }
        .frame(maxHeight: small ? .infinity : nil)
    }

    /// How full, at a glance: green, yellow below half, red when low (green while charging).
    private func gauge(_ row: Row) -> some View {
        let color: Color = row.charging || row.level > 50 ? .green : row.level > 20 ? .yellow : .red
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.12))
            Capsule().fill(color).frame(width: max(3, 24 * CGFloat(row.level) / 100))
        }
        .frame(width: 24, height: 4)
    }

    private func level(_ row: Row) -> some View {
        HStack(spacing: 2) {
            if row.charging {
                Image(systemName: "bolt.fill").font(.system(size: 8))
            }
            Text("\(row.level)%")
                .rollingNumber(row.level)
        }
        .font(HomeType.value)
        .foregroundStyle(row.charging ? Color.green : row.level <= 20 ? Color.red : .white)
    }
}

/// The time in the World Clock Glance's city: a sun or moon for whether it's day there, and how far
/// ahead or behind it is (or that it's already tomorrow).
struct ClockCard: View {
    var small = false
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let city = WorldClock.city
        let zone = TimeZone(identifier: city.zone) ?? .current
        TimelineView(.everyMinute) { context in
            let now = context.date
            HomeTile {
                ViewThatFits(in: .vertical) {
                    if !small { medium(city, zone: zone, now: now) }
                    VStack(alignment: .leading, spacing: 1) {
                        label(city, zone: zone, now: now)
                        HStack(alignment: .firstTextBaseline) {
                            Text(time(now, zone))
                                .font(HomeType.figure)
                            Spacer(minLength: 2)
                            Text(WorldClock.offset(zone, at: now))
                                .font(HomeType.detail)
                                .foregroundStyle(HomeType.secondary)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .lineLimit(1)
            .help("\(city.name), \(WorldClock.offset(zone, at: now))")
        }
    }

    private func medium(_ city: WorldClock.City, zone: TimeZone, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(city, zone: zone, now: now, large: true)
            Spacer(minLength: 8)
            Text(time(now, zone))
                .font(HomeType.bigFigure)
            Text(([day(zone, now: now)].compactMap { $0 } + [WorldClock.offset(zone, at: now)]).joined(separator: " · "))
                .font(HomeType.detail)
                .foregroundStyle(HomeType.secondary)
        }
    }

    private func label(_ city: WorldClock.City, zone: TimeZone, now: Date, large: Bool = false) -> some View {
        var cal = Calendar.current
        cal.timeZone = zone
        let hour = cal.component(.hour, from: now)
        let day = (6..<18).contains(hour)
        return HStack(spacing: 4) {
            Image(systemName: day ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(day ? Color.yellow : Color(red: 0.6, green: 0.65, blue: 1))
            Text(city.name)
                .font(large ? .system(size: 12, weight: .semibold) : HomeType.label)
                .foregroundStyle(large ? .white : HomeType.secondary)
        }
    }

    private func time(_ now: Date, _ zone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        return now.formatted(style)
    }

    /// "Tomorrow" or "Yesterday" when it's another day there.
    private func day(_ zone: TimeZone, now: Date) -> String? {
        var there = Calendar.current
        there.timeZone = zone
        let a = there.dateComponents([.year, .month, .day], from: now)
        let b = Calendar.current.dateComponents([.year, .month, .day], from: now)
        guard let ta = Calendar.current.date(from: a), let tb = Calendar.current.date(from: b), ta != tb else { return nil }
        return ta > tb ? "Tomorrow" : "Yesterday"
    }
}

/// Coding agents at work: a hand for each one waiting on you (first), a sparkle for each one
/// working. Clicking one brings its terminal pane or app forward; nothing is answered from here.
struct AgentsCard: View {
    var small = false
    @ObservedObject private var agents = AgentMonitor.shared
    @ObservedObject private var hooks = AgentHooks.shared

    var body: some View {
        let active = agents.waiting + agents.working
        HomeTile {
            if active.isEmpty {
                HomeNote(symbol: "sparkles", text: "No agents at work")
            } else {
                ViewThatFits(in: .vertical) {
                    ForEach((1...(small ? 2 : 4)).reversed(), id: \.self) { count in
                        list(Array(active.prefix(count)), more: active.count - count)
                    }
                }
            }
        }
        .onAppear { agents.viewerAppeared() }
        .onDisappear { agents.viewerDisappeared() }
    }

    private func list(_ sessions: [AgentMonitor.Session], more: Int) -> some View {
        VStack(alignment: .leading, spacing: small ? 3 : 5) {
            ForEach(sessions) { session in
                Button { agents.focus(session) } label: {
                    HStack(spacing: 6) {
                        Group {
                            if session.state == .waiting {
                                Image(systemName: "hand.raised.fill")
                                    .foregroundStyle(.orange)
                                    .symbolEffect(.pulse, options: .repeating)
                            } else {
                                Image(systemName: "sparkle")
                                    .foregroundStyle(session.tool.tint)
                                    .symbolEffect(.pulse, options: .repeating)
                            }
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14)
                        Text(session.project)
                            .font(HomeType.row.weight(.medium))
                            .foregroundStyle(.white.opacity(session.state == .waiting ? 1 : 0.8))
                            .layoutPriority(1)
                        if !small, let activity = hooks.live(for: session)?.activity {
                            Text(activity)
                                .font(HomeType.detail)
                                .foregroundStyle(HomeType.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(session.tool.name) · \(session.project)" + (session.state == .waiting ? ": waiting for you" : ": working"))
            }
            if more > 0 {
                Text("+\(more) more")
                    .font(HomeType.detail)
                    .foregroundStyle(HomeType.secondary)
                    .padding(.leading, 20)
            }
        }
    }
}

/// The newest files on the Shelf as thumbnails, each one dragged straight out into another app
/// (it stays on the Shelf). Clicking opens the Shelf.
struct ShelfCard: View {
    var small = false
    @EnvironmentObject private var shelf: ShelfStore

    var body: some View {
        let items = Array(shelf.items.suffix(small ? 3 : 4).reversed())
        HomeTile {
            if items.isEmpty {
                HomeNote(symbol: "tray", text: "Drop files on the notch")
            } else if small {
                HStack(spacing: 6) {
                    ForEach(items) { thumb($0, side: 34) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    LazyVGrid(columns: [GridItem(.fixed(48), spacing: 8), GridItem(.fixed(48), spacing: 8)], spacing: 8) {
                        ForEach(items) { thumb($0, side: 48) }
                    }
                    Spacer(minLength: 0)
                    Text(shelf.items.count == 1 ? "1 file" : "\(shelf.items.count) files")
                        .font(HomeType.detail)
                        .foregroundStyle(HomeType.secondary)
                }
            }
        }
    }

    private func thumb(_ item: ShelfItem, side: CGFloat) -> some View {
        Image(nsImage: item.isVisual ? item.thumbnail : item.icon)
            .resizable()
            .aspectRatio(contentMode: item.isVisual ? .fill : .fit)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(FileDragSource(items: [item], onClick: openShelf, removesDelivered: false))
            .help(item.url.lastPathComponent)
    }

    private func openShelf() {
        NotchPresenter.shared.primary?.open(tab: .shelf, takeKeyboard: false)
    }
}

/// The Timer at a glance: a ring for how far along it is, the time, and start or pause. Idle, it
/// offers the Timer tab's own mode and length.
struct TimerCard: View {
    var small = false
    @EnvironmentObject private var timer: TimerStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HomeTile {
                ViewThatFits(in: .vertical) {
                    if !small { medium }
                    compact
                }
            }
        }
    }

    private var label: String {
        let mode = timer.isActive ? timer.runningMode : timer.mode
        return mode == .pomodoro ? timer.phase.label : mode.label
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: timer.isActive ? max(0.01, timer.progress) : 0)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: timer.progress)
            Image(systemName: (timer.isActive ? timer.runningMode : timer.mode).icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(timer.isActive ? AnyShapeStyle(.orange) : AnyShapeStyle(.white.opacity(0.7)))
        }
    }

    private var button: some View {
        Button {
            switch timer.state {
            case .idle: timer.start()
            case .running: timer.pause()
            case .paused: timer.resume()
            }
        } label: {
            Image(systemName: timer.state == .running ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(timer.state == .running ? .white : .orange)
                .frame(width: 26, height: 26)
                .background(Circle().fill(timer.state == .running ? Color.white.opacity(0.14) : Color.orange.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .help(timer.state == .running ? "Pause" : timer.state == .paused ? "Resume" : "Start")
    }

    private var compact: some View {
        HStack(spacing: 8) {
            ring.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(HomeType.label)
                    .foregroundStyle(HomeType.secondary)
                Text(timer.displayTime)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            button
        }
        .frame(maxHeight: .infinity)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ring.frame(width: 44, height: 44)
                Spacer(minLength: 0)
                button
            }
            Spacer(minLength: 6)
            Text(label)
                .font(HomeType.label)
                .foregroundStyle(HomeType.secondary)
            Text(timer.displayTime)
                .font(HomeType.bigFigure)
        }
        .lineLimit(1)
    }
}

/// Music as a narrow tile, when Home is full: the artwork with play or pause, and the song.
/// Full height (alone in its column), it's all down the middle: the artwork, the song and artist,
/// then the controls. Clicking the artwork goes to the app playing it.
struct MusicTile: View {
    @EnvironmentObject private var media: MediaController

    var body: some View {
        HomeTile {
            ViewThatFits(in: .vertical) {
                tall
                short
            }
        }
    }

    private var tall: some View {
        VStack(spacing: 8) {
            art(56)
            VStack(spacing: 1) {
                Text(media.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(media.artist)
                    .font(HomeType.detail)
                    .foregroundStyle(HomeType.secondary)
            }
            .lineLimit(1)
            HStack(spacing: 4) {
                Button { media.previousTrack() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 11))
                }
                .buttonStyle(NotchIconButtonStyle(size: 26))
                Button { media.togglePlayPause() } label: {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(NotchIconButtonStyle(size: 30))
                .help(media.isPlaying ? "Pause" : "Play")
                Button { media.nextTrack() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 11))
                }
                .buttonStyle(NotchIconButtonStyle(size: 26))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var short: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                art(30)
                Spacer(minLength: 0)
                playPause
            }
            Text(media.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxHeight: .infinity)
    }

    private func art(_ size: CGFloat) -> some View {
        AlbumArtView(image: media.artwork, size: size, cornerRadius: size > 40 ? 10 : 7)
            .onTapGesture { media.openSourceApp() }
            .help(media.appName.map { "Open \($0)" } ?? "")
    }

    private var playPause: some View {
        Button { media.togglePlayPause() } label: {
            Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(media.isPlaying ? "Pause" : "Play")
    }
}

/// What was copied last, newest first: click one to copy it again. Small: just the latest.
struct ClipboardCard: View {
    var small = false
    @EnvironmentObject private var clipboard: ClipboardHistory

    var body: some View {
        let clips = Array(clipboard.clips.prefix(small ? 1 : 4))
        HomeTile {
            if clips.isEmpty {
                HomeNote(symbol: "doc.on.clipboard", text: "Nothing copied yet")
            } else if small, let clip = clips.first {
                row(clip, lines: 2)
                    .frame(maxHeight: .infinity)
            } else {
                ViewThatFits(in: .vertical) {
                    ForEach((1...clips.count).reversed(), id: \.self) { count in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(clips.prefix(count)) { row($0, lines: 1) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ clip: ClipboardHistory.Clip, lines: Int) -> some View {
        Button { clipboard.copy(clip) } label: {
            HStack(alignment: lines > 1 ? .top : .center, spacing: 6) {
                if clip.isPicture, let image = clipboard.thumbnail(for: clip) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: icon(clip.kind))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Optional(clip.kind).tint ?? .white.opacity(0.5))
                        .frame(width: 18, height: 18)
                }
                Text(clip.title.replacingOccurrences(of: "\n", with: " "))
                    .font(HomeType.row)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(lines)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy again")
    }

    private func icon(_ kind: ClipboardHistory.Clip.Kind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .files: "doc"
        }
    }
}

/// Unread counts from the Dock's badges, most first: each app's icon and its number. Clicking one
/// opens that app.
struct UnreadCard: View {
    var small = false
    @ObservedObject private var unread = UnreadBadges.shared

    var body: some View {
        HomeTile {
            if !AXIsProcessTrusted() {
                HomeNote(symbol: "lock", text: "Needs Accessibility")
            } else if unread.badges.isEmpty {
                HomeNote(symbol: "checkmark.circle", text: "All caught up")
            } else if small {
                HStack(spacing: 8) {
                    Text("\(unread.total)")
                        .font(HomeType.figure)
                        .rollingNumber(unread.total)
                    HStack(spacing: -6) {
                        ForEach(unread.badges.prefix(3)) { icon($0, size: 22) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else {
                ViewThatFits(in: .vertical) {
                    ForEach((1...min(4, unread.badges.count)).reversed(), id: \.self) { count in
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(unread.badges.prefix(count)) { badge in
                                Button { NSWorkspace.shared.openApplication(at: badge.appURL, configuration: .init()) } label: {
                                    HStack(spacing: 7) {
                                        icon(badge, size: 18)
                                        Text(badge.name)
                                            .font(HomeType.row)
                                            .foregroundStyle(.white.opacity(0.8))
                                        Spacer(minLength: 4)
                                        Text("\(badge.count)")
                                            .font(HomeType.value)
                                            .rollingNumber(badge.count)
                                    }
                                    .lineLimit(1)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open \(badge.name)")
                            }
                        }
                    }
                }
            }
        }
        .onAppear { unread.viewerAppeared() }
        .onDisappear { unread.viewerDisappeared() }
    }

    private func icon(_ badge: UnreadBadges.Badge, size: CGFloat) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: badge.appURL.path))
            .resizable()
            .frame(width: size, height: size)
    }
}

/// The Notes tab's scratchpad, to type into right here. The notch stays open while it has the
/// keyboard, as it does on the Notes tab.
struct ScratchpadCard: View {
    @EnvironmentObject private var store: ScratchpadStore
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $store.text)
                .font(.system(size: 11.5))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
                .onKeyPress(.escape) { focused = false; return .handled }
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
            if store.text.isEmpty {
                Text("Jot something down…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A field to type in, so unlike the other tiles it keeps its panel.
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(focused ? 0.1 : 0.06)).padding(-6))
        .animation(.easeOut(duration: 0.15), value: focused)
        .onChange(of: focused) { _, f in NotchPresenter.shared.primary?.isEditing = f }
    }
}

/// How fast the connection's going: down and up, a line of the last minute's download (medium), and
/// a shield while a VPN is on.
struct NetworkCard: View {
    var small = false
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        HomeTile {
            ViewThatFits(in: .vertical) {
                if !small {
                    VStack(alignment: .leading, spacing: 0) {
                        status
                        Spacer(minLength: 4)
                        RateLine(values: network.downHistory)
                            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                            .frame(height: 28)
                        Spacer(minLength: 4)
                        rates
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    status
                    rates
                }
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear { network.viewerAppeared() }
        .onDisappear { network.viewerDisappeared() }
    }

    private var status: some View {
        HStack(spacing: 5) {
            Image(systemName: network.info.kind == .offline ? "wifi.slash" : network.info.kind == .wifi ? "wifi" : "network")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(network.info.kind == .offline ? Color.red : .white.opacity(0.7))
            Text(network.info.kind == .offline ? "Offline" : network.info.ssid ?? network.info.interfaceName)
                .font(HomeType.label)
                .foregroundStyle(HomeType.secondary)
            Spacer(minLength: 0)
            if let vpn = network.info.vpn {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.green)
                    .help("\(vpn) is on")
            }
        }
        .lineLimit(1)
    }

    /// Down and up side by side, or one over the other when that's too wide.
    private var rates: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                rate("arrow.down", network.downRate)
                rate("arrow.up", network.upRate)
            }
            VStack(alignment: .leading, spacing: 1) {
                rate("arrow.down", network.downRate)
                rate("arrow.up", network.upRate)
            }
        }
    }

    private func rate(_ icon: String, _ bytes: Double) -> some View {
        let r = formatRate(bytes)
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            Text(r.value).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            Text(r.unit.replacingOccurrences(of: "/s", with: "")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
        }
        .fixedSize()
    }
}

/// A line through recent values, scaled to the tallest.
struct RateLine: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let top = max(values.max() ?? 0, 1)
        for (i, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1),
                                y: rect.maxY - rect.height * CGFloat(value / top))
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

/// Days to go until the date set for the Countdown (shared with its Glance). Without one, clicking
/// goes to where it's set.
struct CountdownCard: View {
    var small = false
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TimelineView(.everyMinute) { context in
            HomeTile {
                if let target = Countdown.target {
                    let text = Countdown.text(at: context.date)
                    if small {
                        VStack(alignment: .leading, spacing: 1) {
                            title
                            Text(text)
                                .font(HomeType.figure)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            title
                            Spacer(minLength: 0)
                            Text(text)
                                .font(HomeType.bigFigure)
                            Text(target, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                .font(HomeType.detail)
                                .foregroundStyle(HomeType.secondary)
                        }
                    }
                } else {
                    Button { SettingsWindowController.shared.show(pane: .home) } label: {
                        HomeNote(symbol: "hourglass", text: "Pick a date in Settings")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var title: some View {
        HStack(spacing: 4) {
            Image(systemName: "hourglass").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.orange)
            Text(settings.countdownTitle.isEmpty ? "Countdown" : settings.countdownTitle)
                .font(HomeType.label)
        }
        .foregroundStyle(HomeType.secondary)
        .lineLimit(1)
    }
}
