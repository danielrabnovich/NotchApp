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
