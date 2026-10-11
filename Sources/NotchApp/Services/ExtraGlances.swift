import AppKit
import ApplicationServices

/// The World Clock Glance's cities.
enum WorldClock {
    struct City: Hashable, Identifiable {
        let name: String
        /// What the Glance says ("LDN").
        let short: String
        let zone: String
        var id: String { zone + name }
    }

    static let cities: [City] = [
        City(name: "Honolulu", short: "HNL", zone: "Pacific/Honolulu"), City(name: "Los Angeles", short: "LA", zone: "America/Los_Angeles"),
        City(name: "Denver", short: "DEN", zone: "America/Denver"), City(name: "Chicago", short: "CHI", zone: "America/Chicago"),
        City(name: "New York", short: "NYC", zone: "America/New_York"), City(name: "Toronto", short: "TOR", zone: "America/Toronto"),
        City(name: "Mexico City", short: "MEX", zone: "America/Mexico_City"), City(name: "São Paulo", short: "SAO", zone: "America/Sao_Paulo"),
        City(name: "London", short: "LDN", zone: "Europe/London"), City(name: "Lisbon", short: "LIS", zone: "Europe/Lisbon"),
        City(name: "Paris", short: "PAR", zone: "Europe/Paris"), City(name: "Berlin", short: "BER", zone: "Europe/Berlin"),
        City(name: "Amsterdam", short: "AMS", zone: "Europe/Amsterdam"), City(name: "Stockholm", short: "STO", zone: "Europe/Stockholm"),
        City(name: "Athens", short: "ATH", zone: "Europe/Athens"), City(name: "Istanbul", short: "IST", zone: "Europe/Istanbul"),
        City(name: "Tel Aviv", short: "TLV", zone: "Asia/Jerusalem"), City(name: "Dubai", short: "DXB", zone: "Asia/Dubai"),
        City(name: "Mumbai", short: "BOM", zone: "Asia/Kolkata"), City(name: "Bangkok", short: "BKK", zone: "Asia/Bangkok"),
        City(name: "Singapore", short: "SIN", zone: "Asia/Singapore"), City(name: "Hong Kong", short: "HKG", zone: "Asia/Hong_Kong"),
        City(name: "Shanghai", short: "SHA", zone: "Asia/Shanghai"), City(name: "Seoul", short: "SEL", zone: "Asia/Seoul"),
        City(name: "Tokyo", short: "TYO", zone: "Asia/Tokyo"), City(name: "Sydney", short: "SYD", zone: "Australia/Sydney"),
        City(name: "Auckland", short: "AKL", zone: "Pacific/Auckland"), City(name: "UTC", short: "UTC", zone: "UTC"),
    ]

    @MainActor static var city: City {
        cities.first { $0.id == AppSettings.shared.worldClockCity } ?? cities.first { $0.name == "London" }!
    }

    /// "+5h", "−3h", "+5:30" from here.
    static func offset(_ zone: TimeZone, at date: Date = Date()) -> String {
        let seconds = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        guard seconds != 0 else { return "same time" }
        let h = abs(seconds) / 3600, m = abs(seconds) % 3600 / 60
        return (seconds > 0 ? "+" : "−") + (m == 0 ? "\(h)h" : "\(h):\(String(format: "%02d", m))")
    }
}

/// When the light's good: the hour after sunrise and the hour before sunset, from the weather's sun times.
enum GoldenHour {
    struct Reading {
        /// "34m", "1h 10m", "7:12"
        let text: String
        let icon: String
        /// It's golden hour now.
        let golden: Bool
        /// Sunset is within three hours (for "only near sunset").
        let near: Bool
        let detail: String
    }

    @MainActor static func now(_ date: Date = Date()) -> Reading? {
        let days = TodayWeather.shared.report?.days ?? []
        guard let today = days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) ?? days.first,
              let sunrise = today.sunrise, let sunset = today.sunset else { return nil }
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let detail = "Sunrise \(sunrise.formatted(time)) · sunset \(sunset.formatted(time))"
        let goldenStart = sunset.addingTimeInterval(-3600)
        if date >= goldenStart && date < sunset {
            return Reading(text: span(sunset.timeIntervalSince(date)), icon: "sun.horizon.fill", golden: true, near: true,
                           detail: "Golden hour until sunset at \(sunset.formatted(time))")
        }
        if date >= sunrise && date < sunrise.addingTimeInterval(3600) {
            return Reading(text: span(sunrise.addingTimeInterval(3600).timeIntervalSince(date)), icon: "sunrise.fill", golden: true, near: false,
                           detail: "Morning golden hour · \(detail)")
        }
        if date < goldenStart, date > sunrise {
            return Reading(text: span(goldenStart.timeIntervalSince(date)), icon: "sun.horizon", golden: false,
                           near: goldenStart.timeIntervalSince(date) < 3 * 3600, detail: "Golden hour at \(goldenStart.formatted(time)) · \(detail)")
        }
        // Night: the next sunrise.
        let next = date < sunrise ? sunrise : (days.dropFirst().first?.sunrise ?? sunrise.addingTimeInterval(86400))
        return Reading(text: next.formatted(time), icon: "sunrise", golden: false, near: false, detail: "Sunrise \(next.formatted(time))")
    }

    private static func span(_ seconds: TimeInterval) -> String {
        let m = max(1, Int(seconds / 60))
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}

/// The badge counts on Dock icons (Slack, Discord, Mail, Messages…), read through Accessibility
/// every few seconds while the Unread Glance is pinned.
@MainActor
final class UnreadBadges: ObservableObject {
    static let shared = UnreadBadges()

    struct Badge: Identifiable, Equatable {
        let name: String
        let count: Int
        let appURL: URL
        var id: URL { appURL }
    }

    /// Most first.
    @Published private(set) var badges: [Badge] = []
    var total: Int { badges.reduce(0) { $0 + $1.count } }
    private var timer: Timer?

    func setDemand(_ wanted: Bool) {
        guard wanted != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard wanted else { badges = []; return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { UnreadBadges.shared.poll() } }
    }

    private func poll() {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let pid = dock.processIdentifier
        Task.detached(priority: .utility) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            var found: [Badge] = []
            for list in (AXReader.value(app, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for item in (AXReader.value(list, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    // Numbers only: "•" (something new, no count) and words aren't unread messages.
                    guard let label: String = AXReader.value(item, "AXStatusLabel"),
                          let count = Int(label.filter(\.isNumber)), count > 0,
                          let url: URL = AXReader.value(item, "AXURL") else { continue }
                    let name: String = AXReader.value(item, kAXTitleAttribute) ?? url.deletingPathExtension().lastPathComponent
                    found.append(Badge(name: name, count: count, appURL: url))
                }
            }
            found.sort { $0.count > $1.count }
            await MainActor.run { if UnreadBadges.shared.badges != found { UnreadBadges.shared.badges = found } }
        }
    }

    /// Clicking: the app with the most waiting.
    func openTop() {
        guard let top = badges.first else { return }
        NSWorkspace.shared.openApplication(at: top.appURL, configuration: .init())
    }
}

/// The Countdown Glance: days (or hours, near the end) until a date you set.
enum Countdown {
    @MainActor static var target: Date? {
        let t = AppSettings.shared.countdownDate
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// "12d", "1d 4h", "5h", "Today", "Done"
    @MainActor static func text(at now: Date = Date()) -> String {
        guard let target else { return "Set" }
        let seconds = target.timeIntervalSince(now)
        if seconds <= 0 { return Calendar.current.isDate(target, inSameDayAs: now) ? "Today" : "Done" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                                   to: Calendar.current.startOfDay(for: target)).day ?? 0
        if days >= 2 { return "\(days)d" }
        let hours = Int(seconds / 3600)
        return hours >= 24 ? "1d \(hours - 24)h" : hours >= 1 ? "\(hours)h" : "\(max(1, Int(seconds / 60)))m"
    }
}
