import AppKit
import SwiftUI

/// Which Focus is on (Do Not Disturb, Work, Sleep…), with its own symbol and color. macOS has no
/// public way to ask, so this reads Focus's own files in ~/Library/DoNotDisturb/DB, which takes
/// Full Disk Access: the Focuses turned on (Assertions.json) and how each looks and when its
/// schedules run (ModeConfigurations.json). The folder is watched, so a change shows at once.
@MainActor
final class FocusMonitor: ObservableObject {
    static let shared = FocusMonitor()

    struct Focus: Equatable {
        let id: String
        let name: String
        let symbol: String
        let color: NSColor
        /// When it was turned on, for one turned on by hand or by an automation.
        var since: Date?
        /// When a scheduled one ends.
        var until: Date?

        /// "Do Not Disturb" is long for beside the notch.
        var shortName: String { name == "Do Not Disturb" ? "DND" : name }
    }

    @Published private(set) var current: Focus?
    /// Focus's files can be read (Full Disk Access is on).
    @Published private(set) var readable = false

    private static let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/DoNotDisturb/DB")
    private var demand = false
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?

    private init() {}

    /// Whether Focus's files can be read right now (no prompt: macOS doesn't ask for this one).
    nonisolated static var canRead: Bool {
        (try? Data(contentsOf: folder.appendingPathComponent("ModeConfigurations.json"))) != nil
    }

    func setDemand(_ wanted: Bool) {
        guard wanted != demand else { return }
        demand = wanted
        if wanted {
            refresh()
            watch()
            // Schedules start and end with the clock, not with a change to the files.
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { FocusMonitor.shared.refresh() }
            }
        } else {
            source?.cancel()
            source = nil
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let (readable, focus) = Self.read()
            await MainActor.run {
                let me = FocusMonitor.shared
                if me.readable != readable { me.readable = readable }
                if me.current != focus { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { me.current = focus } }
                // Access granted since the last look: start watching the folder now.
                if readable, me.demand, me.source == nil { me.watch() }
            }
        }
    }

    /// Focus writes its files anew (into the folder) on every change; the folder's own change is the signal.
    private func watch() {
        guard source == nil else { return }
        let fd = open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler {
            MainActor.assumeIsolated {
                // A burst of writes for one change: read once it settles.
                FocusMonitor.shared.refreshSoon()
            }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private var pending: DispatchWorkItem?
    private func refreshSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { FocusMonitor.shared.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - Reading Focus's files

    private nonisolated static func json(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private nonisolated static func read(now: Date = Date()) -> (readable: Bool, focus: Focus?) {
        guard let modes = json("ModeConfigurations.json") else { return (false, nil) }
        let configs = ((modes["data"] as? [[String: Any]])?.first?["modeConfigurations"] as? [String: Any]) ?? [:]

        func focus(_ id: String) -> Focus {
            let mode = (configs[id] as? [String: Any])?["mode"] as? [String: Any]
            let name = mode?["name"] as? String ?? "Focus"
            let symbol = (mode?["symbolImageName"] as? String).flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil }
                ?? "moon.fill"
            return Focus(id: id, name: name, symbol: symbol, color: color(mode?["tintColorName"] as? String))
        }

        // Turned on by hand, from Control Center or by an automation: the latest one counts.
        let assertions = json("Assertions.json")
        let records = ((assertions?["data"] as? [[String: Any]])?.first?["storeAssertionRecords"] as? [[String: Any]]) ?? []
        if let latest = records.max(by: { ($0["assertionStartDateTimestamp"] as? Double ?? 0) < ($1["assertionStartDateTimestamp"] as? Double ?? 0) }),
           let id = (latest["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String {
            var f = focus(id)
            f.since = (latest["assertionStartDateTimestamp"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }
            return (true, f)
        }

        // Otherwise a schedule that's running now.
        for (id, value) in configs {
            let triggers = ((value as? [String: Any])?["triggers"] as? [String: Any])?["triggers"] as? [[String: Any]] ?? []
            for t in triggers where (t["class"] as? String)?.contains("Schedule") == true {
                guard (t["enabledSetting"] as? Int) == 2, let end = scheduleEnd(t, now: now) else { continue }
                var f = focus(id)
                f.until = end
                return (true, f)
            }
        }
        return (true, nil)
    }

    /// When a schedule running now ends, or nil when it isn't running. Its weekdays are a bit
    /// field, Sunday first; a span past midnight belongs to the day it started.
    private nonisolated static func scheduleEnd(_ t: [String: Any], now: Date) -> Date? {
        guard let sh = t["timePeriodStartTimeHour"] as? Int, let sm = t["timePeriodStartTimeMinute"] as? Int,
              let eh = t["timePeriodEndTimeHour"] as? Int, let em = t["timePeriodEndTimeMinute"] as? Int else { return nil }
        let cal = Calendar.current
        let weekdays = t["timePeriodWeekdays"] as? Int ?? 127
        let start = sh * 60 + sm, end = eh * 60 + em
        let c = cal.dateComponents([.hour, .minute, .weekday], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let today = (c.weekday ?? 1) - 1, yesterday = (today + 6) % 7
        func on(_ day: Int) -> Bool { weekdays & (1 << day) != 0 }
        let startOfDay = cal.startOfDay(for: now)
        if start < end {
            guard on(today), minute >= start, minute < end else { return nil }
            return startOfDay.addingTimeInterval(TimeInterval(end * 60))
        }
        // Overnight (10 PM – 7 AM).
        if minute >= start, on(today) { return startOfDay.addingTimeInterval(TimeInterval((24 * 60 + end) * 60)) }
        if minute < end, on(yesterday) { return startOfDay.addingTimeInterval(TimeInterval(end * 60)) }
        return nil
    }

    private nonisolated static func color(_ name: String?) -> NSColor {
        switch name?.replacingOccurrences(of: "system", with: "").replacingOccurrences(of: "Color", with: "").lowercased() {
        case "red": .systemRed
        case "orange": .systemOrange
        case "yellow": .systemYellow
        case "green": .systemGreen
        case "mint": .systemMint
        case "teal": .systemTeal
        case "cyan": .systemCyan
        case "blue": .systemBlue
        case "purple": .systemPurple
        case "pink": .systemPink
        case "brown": .systemBrown
        case "gray", "grey": .systemGray
        default: .systemIndigo // Do Not Disturb's
        }
    }

    // MARK: - Turning it off and on

    /// A Shortcut of the user's for Focus ("Toggle Focus", "Do Not Disturb"…): macOS gives apps no
    /// way to change Focus, but a Shortcut with Set Focus in it can.
    var shortcut: ShortcutsApp.Shortcut? {
        ShortcutsApp.shared.all.first { s in
            let n = s.name.lowercased()
            return n.contains("focus") || n.contains("do not disturb") || n.split(separator: " ").contains("dnd")
        }
    }

    /// A click on the Glance: Full Disk Access first; then the user's Focus Shortcut, or Focus settings.
    func click() {
        if !readable { return Permissions.shared.openSettings(.fullDisk) }
        if let shortcut {
            ShortcutsApp.shared.run(shortcut)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { FocusMonitor.shared.refresh() }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
        }
    }

    var clickHint: String {
        if !readable { return "Allow Full Disk Access" }
        if let shortcut { return "Run “\(shortcut.name)”" }
        return "Open Focus Settings"
    }
}
