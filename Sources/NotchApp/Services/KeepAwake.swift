import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt

/// Amphetamine-style sessions: keep the Mac awake indefinitely or for a while, optionally
/// letting the display sleep or staying awake with the lid closed, and stopping by itself when
/// the battery runs low.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    enum Length: Hashable, Identifiable {
        case minutes(Int)
        case indefinitely
        var id: String { if case .minutes(let m) = self { "\(m)" } else { "forever" } }
        var label: String {
            switch self {
            case .indefinitely: "Indefinitely"
            case .minutes(let m) where m < 60: "\(m) minutes"
            case .minutes(let m) where m % 60 == 0: m == 60 ? "1 hour" : "\(m / 60) hours"
            case .minutes(let m): "\(m / 60)h \(m % 60)m"
            }
        }
        static let presets: [Length] = [.minutes(15), .minutes(30), .minutes(60), .minutes(120), .minutes(240), .minutes(480), .indefinitely]
    }

    @Published private(set) var isActive = false
    /// When the session ends by itself (nil while indefinite or off).
    @Published private(set) var endsAt: Date?
    /// Ticks every 30 s while a timed session runs, for the remaining-time label.
    @Published private(set) var now = Date()
    /// The session was started for coding agents (and ends when they're done).
    @Published private(set) var forAgents = false

    /// Keeps the system up; held for the whole session.
    private var systemAssertion: IOPMAssertionID = 0
    /// Keeps the screen on too, unless "Let the display sleep" is on.
    private var displayAssertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var settingsWatch: AnyCancellable?

    init() {
        // Display and lid choices apply to a session that's already running, not just the next one.
        let s = AppSettings.shared
        settingsWatch = s.$keepAwakeDisplay.combineLatest(s.$keepAwakeLidClosed).dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { KeepAwake.shared.applyAssertions() } }
    }

    var remainingText: String? {
        guard let endsAt else { return isActive ? "On" : nil }
        let minutes = max(0, Int(endsAt.timeIntervalSince(now) / 60.0 + 0.99))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    func start(_ length: Length, forAgents: Bool = false) {
        stop(announce: false)
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "NotchApp: Keep Awake" as CFString, &systemAssertion) == kIOReturnSuccess else { return }
        isActive = true
        applyAssertions()
        self.forAgents = forAgents
        if case .minutes(let m) = length { endsAt = Date().addingTimeInterval(Double(m) * 60) } else { endsAt = nil }
        now = Date()
        let t = Timer(timeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { KeepAwake.shared.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        ActivityCenter.shared.show(.notice(title: "Keeping your Mac awake",
                                           detail: forAgents ? "while your agents work" : length == .indefinitely ? "until you turn it off" : "for \(length.label)",
                                           icon: "cup.and.saucer.fill"), for: 2.5)
    }

    func stop(announce: Bool = true) {
        guard isActive else { return }
        IOPMAssertionRelease(systemAssertion)
        systemAssertion = 0
        isActive = false
        applyAssertions()
        forAgents = false
        endsAt = nil
        timer?.invalidate()
        timer = nil
        if announce {
            ActivityCenter.shared.show(.notice(title: "Keep Awake off", detail: "Your Mac can sleep normally", icon: "moon.zzz.fill", tone: .info), for: 2.5)
        }
    }

    /// Matches the display hold and lid sleep to the session and the current settings.
    private func applyAssertions() {
        let s = AppSettings.shared
        let wantsDisplay = isActive && s.keepAwakeDisplay
        if wantsDisplay, displayAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "NotchApp: Keep the display on" as CFString, &displayAssertion)
        } else if !wantsDisplay, displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
        LidSleep.set(disabled: isActive && s.keepAwakeLidClosed)
    }

    /// Turns "Stay awake with the lid closed" on or off. The first time on asks for the
    /// administrator password once, to allow `pmset disablesleep` without it from then on.
    func setLidClosed(_ on: Bool) {
        guard on else { AppSettings.shared.keepAwakeLidClosed = false; return }
        Task {
            var allowed = await LidSleep.isAllowed()
            if !allowed { allowed = await LidSleep.allow() }
            if allowed {
                AppSettings.shared.keepAwakeLidClosed = true
            } else {
                ActivityCenter.shared.show(.notice(title: "Lid closed mode is off", detail: "It needs your administrator password once",
                                                   icon: "lock.fill", tone: .warning), for: 4)
            }
        }
    }

    private func tick() {
        now = Date()
        if let endsAt, now >= endsAt { stop(); return }
        let floor = AppSettings.shared.keepAwakeBatteryFloor
        if floor > 0, let level = Self.batteryLevelOnBattery, level <= floor {
            stop(announce: false)
            ActivityCenter.shared.show(.notice(title: "Keep Awake off", detail: "Battery at \(level)%", icon: "battery.25percent", tone: .warning), for: 4)
        }
    }

    /// Battery percentage while running on battery (nil when plugged in or no battery).
    private static var batteryLevelOnBattery: Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return cur * 100 / max
        }
        return nil
    }
}

/// Lid-closed mode: closing a MacBook's lid sleeps it whatever assertions apps hold, so the only
/// switch is `pmset disablesleep`, which needs root. A sudoers rule limited to exactly
/// `pmset disablesleep 1` and `0` is installed once (one password prompt), and sessions toggle it
/// with `sudo -n` from then on. A marker records that sleep is off, so a crash or force quit is
/// put right on the next launch.
enum LidSleep {
    static let rulePath = "/etc/sudoers.d/notchapp-lid"
    private static let markerKey = "lidSleepDisabled"
    /// Writes run in the order they were asked for.
    private static let queue = DispatchQueue(label: "NotchApp.LidSleep")
    private static var current = false

    /// Turns lid sleep off or back on, without a prompt. Does nothing until the rule is installed.
    static func set(disabled: Bool) {
        if disabled { UserDefaults.standard.set(true, forKey: markerKey) }
        queue.async {
            guard disabled != current || !disabled && UserDefaults.standard.bool(forKey: markerKey) else { return }
            guard pmset(disabled) else { return }
            current = disabled
            if !disabled { UserDefaults.standard.set(false, forKey: markerKey) }
        }
    }

    /// Called at quit, so a Mac that can't sleep isn't left behind.
    static func restoreNow() {
        queue.sync {
            guard current || UserDefaults.standard.bool(forKey: markerKey), pmset(false) else { return }
            current = false
            UserDefaults.standard.set(false, forKey: markerKey)
        }
    }

    /// Whether the rule works, proven by re-applying the current state (which changes nothing).
    static func isAllowed() async -> Bool {
        await withCheckedContinuation { c in
            queue.async {
                let report = Shell.runSync("/usr/bin/pmset", ["-g"], timeout: 5)
                c.resume(returning: report.ok && pmset(report.out.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil))
            }
        }
    }

    /// Installs the rule behind the standard password prompt. By uid, so the user name never
    /// lands in sudoers or the shell. A rule that fails `visudo -c` is removed again.
    static func allow() async -> Bool {
        let rule = "#\(getuid()) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
        let command = "mkdir -p /etc/sudoers.d && echo '\(rule)' > \(rulePath) && chmod 0440 \(rulePath) && /usr/sbin/visudo -c -f \(rulePath) || { rm -f \(rulePath); exit 1; }"
        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
        guard await Shell.runAsAdmin(command, prompt: "NotchApp wants to keep your Mac awake with the lid closed. This adds a rule that only allows turning lid sleep off and on, so you won't be asked again.") else { return false }
        return await isAllowed()
    }

    private static func pmset(_ disabled: Bool) -> Bool {
        Shell.runSync("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", disabled ? "1" : "0"], timeout: 5).ok
    }
}
