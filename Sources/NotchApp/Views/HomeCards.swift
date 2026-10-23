import SwiftUI

/// A card of its own on Home: a soft rounded panel, unlike the page's columns. Glances beside the
/// notch are pills; on Home the same things are tiles.
struct HomeTile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
    }
}

/// How busy the Mac is: the Stats rings, and each one's number in its color. Small: the rings
/// beside the numbers; medium: the rings over them.
struct StatsCard: View {
    var small = false
    @ObservedObject private var stats = SystemMonitor.shared

    var body: some View {
        let s = stats.snapshot
        let memory = s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : 0
        let readings: [(String, Double, Color)] = [("CPU", s.cpuTotal, StatsPalette.cpu)]
            + (s.gpu.map { [("GPU", $0, StatsPalette.gpu)] } ?? [])
            + [("Memory", memory, StatsPalette.memory)]
        HomeTile {
            // Medium, unless Home's too short for it (a call bar above).
            ViewThatFits(in: .vertical) {
                if !small {
                    VStack(alignment: .leading, spacing: 0) {
                        StatRings(diameter: 44)
                        Spacer(minLength: 6)
                        numbers(readings, compact: false)
                    }
                }
                HStack(spacing: 10) {
                    StatRings(diameter: 36)
                    numbers(readings, compact: true)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { NotchPresenter.shared.primary?.open(tab: .stats, takeKeyboard: false) }
        .help("Open Stats")
        .onAppear { stats.viewerAppeared() }
        .onDisappear { stats.viewerDisappeared() }
    }

    /// Compact: the label in its color, shortened ("MEM"); otherwise a dot in its color.
    private func numbers(_ readings: [(String, Double, Color)], compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            ForEach(readings, id: \.0) { label, value, color in
                HStack(spacing: 5) {
                    if !compact { Circle().fill(color).frame(width: 6, height: 6) }
                    Text(compact && label == "Memory" ? "MEM" : label)
                        .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                        .foregroundStyle(compact ? color : .white.opacity(0.6))
                    Spacer(minLength: 2)
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.system(size: compact ? 10.5 : 11, weight: .semibold).monospacedDigit())
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
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer(minLength: 4)
                        level(row)
                    }
                }
                .lineLimit(1)
                .help("\(row.name): \(row.level)%")
            }
        }
        .frame(maxHeight: small ? .infinity : nil)
    }

    private func level(_ row: Row) -> some View {
        HStack(spacing: 2) {
            if row.charging {
                Image(systemName: "bolt.fill").font(.system(size: 8))
            }
            Text("\(row.level)%")
        }
        .font(.system(size: small ? 12 : 11.5, weight: .semibold).monospacedDigit())
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
                                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                            Spacer(minLength: 2)
                            Text(WorldClock.offset(zone, at: now))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.45))
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
                .font(.system(size: 28, weight: .semibold).monospacedDigit())
            Text(([day(zone, now: now)].compactMap { $0 } + [WorldClock.offset(zone, at: now)]).joined(separator: " · "))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
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
                .font(.system(size: large ? 12 : 10.5, weight: large ? .semibold : .medium))
                .foregroundStyle(.white.opacity(large ? 1 : 0.6))
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

    var body: some View {
        let active = agents.waiting + agents.working
        HomeTile {
            if active.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer(minLength: 0)
                    Text("No agents at work")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
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
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(session.state == .waiting ? 1 : 0.8))
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
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
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
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: "tray")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer(minLength: 0)
                    Text("Drop files on the notch")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
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
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
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
                .foregroundStyle(.white.opacity(0.7))
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
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(timer.state == .running ? "Pause" : timer.state == .paused ? "Resume" : "Start")
    }

    private var compact: some View {
        HStack(spacing: 8) {
            ring.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
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
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text(timer.displayTime)
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
        }
        .lineLimit(1)
    }
}

/// Music as a narrow tile, when Home is full: the artwork with play or pause, and the song.
/// Full height (alone in its column), the artwork's bigger and the artist shows too. Clicking the
/// artwork goes to the app playing it.
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                art(52)
                Spacer(minLength: 0)
                playPause
            }
            Spacer(minLength: 8)
            Text(media.title)
                .font(.system(size: 12, weight: .semibold))
            Text(media.artist)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
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
