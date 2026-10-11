import AppKit
import IOKit.ps

@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published private(set) var level = 100
    @Published private(set) var isCharging = false
    @Published private(set) var isPluggedIn = false
    @Published private(set) var hasBattery = false
    /// Low Power Mode is on (the battery turns yellow, as on iPhone).
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var source: CFRunLoopSource?
    private var powerStateObserver: NSObjectProtocol?

    func start() {
        update(initial: true)
        powerStateObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                                    queue: .main) { _ in
            MainActor.assumeIsolated {
                let on = ProcessInfo.processInfo.isLowPowerModeEnabled
                if BatteryMonitor.shared.lowPowerMode != on { BatteryMonitor.shared.lowPowerMode = on }
            }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.update(initial: false) }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func update(initial: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let wasPlugged = isPluggedIn

        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            level = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            isPluggedIn = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }

        if !initial, hasBattery, isPluggedIn, !wasPlugged, AppSettings.shared.chargingAnimation {
            ActivityCenter.shared.show(.charging(level: level), for: 3.2)
        }
    }
}
