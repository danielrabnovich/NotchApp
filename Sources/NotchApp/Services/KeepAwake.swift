import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt

/// Amphetamine-style sessions: keep the Mac awake indefinitely or for a while, optionally
/// letting the display sleep, and stopping by itself when the battery runs low.
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

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    var remainingText: String? {
        guard let endsAt else { return isActive ? "On" : nil }
        let minutes = max(0, Int(endsAt.timeIntervalSince(now) / 60.0 + 0.99))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    func start(_ length: Length, forAgents: Bool = false) {
        stop(announce: false)
        let type = AppSettings.shared.keepAwakeDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                                                       : kIOPMAssertionTypePreventUserIdleSystemSleep
        guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "NotchApp: Keep Awake" as CFString, &assertion) == kIOReturnSuccess else { return }
        isActive = true
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
        IOPMAssertionRelease(assertion)
        assertion = 0
        isActive = false
        forAgents = false
        endsAt = nil
        timer?.invalidate()
        timer = nil
        if announce {
            ActivityCenter.shared.show(.notice(title: "Keep Awake off", detail: "Your Mac can sleep normally", icon: "moon.zzz.fill", tone: .info), for: 2.5)
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
