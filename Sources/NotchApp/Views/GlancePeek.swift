import IOKit.ps
import SwiftUI

/// What a Glance says when the pointer rests on it: a card that drops under the notch like a
/// Banner, with more than fits beside the notch, and what a click does. It takes the place of
/// a tooltip, which looks out of place on the black notch.
@MainActor
enum GlancePeek {
    struct Content: Equatable {
        var icon: String
        var tint: Color
        var title: String
        var detail: String
        /// What a click does ("Open Stats"), shown faintly at the right.
        var action: String?
    }

    static func content(for item: LiveItem) -> Content {
        var c = Content(icon: item.icon, tint: item.tint, title: item.title, detail: item.detail, action: action(for: item))
        switch item {
        case .duo:
            // The network leads (with its VPN); the battery and the sound follow.
            let s = DuoGlyph.summary.components(separatedBy: " · ")
            let net = s.prefix { !$0.hasPrefix("Battery") && !$0.hasPrefix("CPU") && !$0.hasPrefix("Volume") && $0 != "Muted" }
            c.title = net.joined(separator: " · ").nilIfEmpty ?? "Duo"
            c.detail = ([batteryLine()].compactMap { $0 } + s.dropFirst(net.count).filter { !$0.hasPrefix("Battery") }).joined(separator: " · ")
        case .battery:
            let b = BatteryMonitor.shared
            c.title = "Battery \(b.level)%" + (b.isCharging ? ", charging" : b.isPluggedIn ? ", on power" : "")
            c.detail = [timeLeft(), b.lowPowerMode ? "Low Power Mode" : nil].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "Estimating…"
        case .rings:
            c.title = [LiveItem.cpu, .gpu, .memory].map { "\($0.title) \(reading($0))" }.filter { !$0.hasSuffix("–") }.joined(separator: " · ")
            c.detail = [LiveItem.temperature, .power].map { "\($0 == .temperature ? "Temp" : $0.title) \(reading($0))" }
                .filter { !$0.hasSuffix("–") }.joined(separator: " · ")
        case .cpu, .gpu, .memory, .temperature, .power:
            c.title = "\(item.title) · \(reading(item))"
            c.detail = [LiveItem.cpu, .memory, .gpu, .temperature, .power].filter { $0 != item }
                .map { "\($0 == .temperature ? "Temp" : $0.title) \(reading($0))" }.filter { !$0.hasSuffix("–") }.joined(separator: " · ")
        case .music:
            let m = MediaController.shared
            c.title = m.title.isEmpty ? "Nothing playing" : m.title
            c.detail = [m.artist, m.album].filter { !$0.isEmpty }.joined(separator: " — ")
        case .weather:
            if let r = TodayWeather.shared.report {
                c.icon = WeatherReport.symbol(r.currentCode)
                c.title = "\(Int(r.currentTemp.rounded()))° in \(r.place) · \(WeatherReport.describe(r.currentCode).lowercased())"
                var parts = ["Feels \(Int(r.feelsLike.rounded()))°"]
                if let today = r.days.first { parts.append("High \(Int(today.high.rounded()))° · low \(Int(today.low.rounded()))° · \(today.rainChance)% rain") }
                if r.days.count > 1 { parts.append("Tomorrow \(WeatherReport.describe(r.days[1].code).lowercased())") }
                c.detail = parts.joined(separator: " · ")
            }
        case .unread:
            let badges = UnreadBadges.shared.badges
            c.title = badges.isEmpty ? "Nothing unread" : "\(UnreadBadges.shared.total) unread"
            c.detail = badges.map { "\($0.name) \($0.count)" }.joined(separator: " · ")
        case .devices:
            let devices = DeviceBatteries.shared.devices.filter { $0.level != nil }
            if let low = DeviceBatteries.shared.lowest { c.title = "\(low.name) · \(low.level ?? 0)%" }
            c.detail = devices.map { "\($0.name) \($0.level ?? 0)%" }.joined(separator: " · ").nilIfEmpty ?? "No battery-powered devices connected"
        case .nextEvent:
            if let event = LiveActivities.nextEvent() {
                c.title = event.title ?? "Event"
                let time = event.startDate.formatted(date: .omitted, time: .shortened)
                let link = MeetingLinks.find(in: event) != nil ? "has a call link" : nil
                c.detail = [time, event.location?.nilIfEmpty, link].compactMap { $0 }.joined(separator: " · ")
            } else {
                c.title = "Nothing else today"
            }
        case .network:
            let n = NetworkMonitor.shared, info = n.info
            c.title = "↓ \(formatRate(n.downRate).value) \(formatRate(n.downRate).unit)   ↑ \(formatRate(n.upRate).value) \(formatRate(n.upRate).unit)"
            c.detail = [info.ssid.map { "Wi-Fi “\($0)”" } ?? info.interfaceName.nilIfEmpty, info.localIP].compactMap { $0 }.joined(separator: " · ")
        case .worldClock, .goldenHour, .countdown, .progress, .agents, .vpn, .timer, .keepAwake, .disk, .meeting:
            c.detail = GlanceActions.hint(for: item)
        case .focus:
            let f = FocusMonitor.shared
            if !f.readable {
                c.title = "Focus needs Full Disk Access"
                c.detail = "macOS keeps which Focus is on where only Full Disk Access can read it"
            } else if let on = f.current {
                c.icon = on.symbol
                c.tint = Color(nsColor: on.color)
                c.title = on.name == "Do Not Disturb" ? on.name : "\(on.name) Focus"
                c.detail = on.until.map { "On a schedule until \($0.formatted(date: .omitted, time: .shortened))" }
                    ?? on.since.map { "On since \($0.formatted(date: .omitted, time: .shortened))" } ?? "On"
            } else {
                c.title = "No Focus on"
                c.detail = f.shortcut.map { "Click to run “\($0.name)”" } ?? "Add a Shortcut with Focus in its name to turn one on from here"
            }
        case .shortcuts:
            c.detail = ShortcutsApp.shared.glanceShortcuts.map(\.name).joined(separator: " · ").nilIfEmpty ?? "Pick Shortcuts in Settings → Glances"
        case .appAction:
            c.title = AppActions.shared.context?.appName ?? "App Actions"
            c.detail = AppActions.shared.glanceActions.map(\.title).joined(separator: " · ")
        default:
            break
        }
        return c
    }

    /// The click, for Glances whose click does something other than show more.
    private static func action(for item: LiveItem) -> String? {
        switch item {
        case .worldClock, .goldenHour, .countdown, .weather, .unread, .progress: nil
        case .duo: "Open Controls"
        case .focus: FocusMonitor.shared.clickHint
        case .shortcuts: ShortcutsApp.shared.glanceShortcuts.count == 1 ? "Run" : nil
        case .appAction: AppActions.shared.glanceActions.count == 1 ? "Run" : nil
        case .cpu, .gpu, .memory, .temperature, .power, .battery, .rings: "Open Stats"
        default: GlanceActions.hint(for: item)
        }
    }

    private static func reading(_ item: LiveItem) -> String {
        let s = SystemMonitor.shared.snapshot
        switch item {
        case .cpu: return "\(Int((s.cpuTotal * 100).rounded()))%"
        case .gpu: return s.gpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
        case .memory: return s.memory.total > 0 ? "\(Int((Double(s.memory.used) / Double(s.memory.total) * 100).rounded()))%" : "–"
        case .temperature:
            guard let t = s.cpuTemp else { return "–" }
            return AppSettings.shared.useFahrenheit ? "\(Int((t * 9 / 5 + 32).rounded()))°F" : "\(Int(t.rounded()))°"
        case .power: return s.systemPower.map { $0 < 10 ? String(format: "%.1f W", $0) : "\(Int($0.rounded())) W" } ?? "–"
        default: return ""
        }
    }

    private static func batteryLine() -> String? {
        let b = BatteryMonitor.shared
        guard b.hasBattery else { return nil }
        return ["Battery \(b.level)%", timeLeft()].compactMap { $0 }.joined(separator: ", ")
    }

    /// "3:12 left" on battery, "full in 0:45" while charging; nil while macOS is still estimating.
    private static func timeLeft() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int ?? -1
            guard minutes > 0 else { return nil }
            let text = "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
            return charging ? "full in \(text)" : "\(text) left"
        }
        return nil
    }
}

/// The card itself: the Glance's glyph in a tinted circle, two lines, and the click at the right.
struct GlancePeekCard: View {
    let item: LiveItem

    var body: some View {
        // Live values (network rates, the weather) keep current while it's up.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let c = GlancePeek.content(for: item)
            HStack(spacing: 11) {
                Group {
                    if item == .duo {
                        DuoGlyph(diameter: 20, scrollable: false)
                    } else if item == .rings {
                        StatRings(diameter: 20)
                    } else {
                        Image(systemName: c.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(c.tint)
                    }
                }
                .frame(width: 30, height: 30)
                .background(Circle().fill(item == .duo || item == .rings ? .white.opacity(0.08) : c.tint.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    if !c.detail.isEmpty {
                        Text(c.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.62))
                            .truncationMode(.tail)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let action = c.action {
                    Text(action)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .animation(.snappy(duration: 0.25), value: c)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.bottom, 6)
    }
}
