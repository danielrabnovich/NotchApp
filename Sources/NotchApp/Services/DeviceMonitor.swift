import AppKit
import CoreAudio
import CoreMediaIO
import SwiftUI

/// Battery levels of connected Bluetooth devices (AirPods, Magic Mouse, keyboards…), with a
/// heads-up when one runs low.
@MainActor
final class DeviceBatteries: ObservableObject {
    static let shared = DeviceBatteries()

    struct Device: Identifiable, Equatable {
        enum Kind { case headphones, mouse, keyboard, trackpad, gamepad, other }
        var id: String { address.isEmpty ? name : address }
        let name: String
        let address: String
        let kind: Kind
        var main: Int?
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        /// Apple's Bluetooth product ID ("0x2024"), which says which AirPods or Beats they are.
        var productID: Int? = nil

        /// The level that matters: the emptier bud, or the device itself.
        var level: Int? { [main, left, right].compactMap { $0 }.min() }

        /// The symbol for the model, by Apple's product ID, else by name; the current AirPods
        /// shape when nothing says more.
        nonisolated static func headphoneSymbol(productID: Int?, name: String) -> String {
            switch productID {
            case 0x2002, 0x200F: return "airpods"                         // AirPods (1st, 2nd generation)
            case 0x2013: return "airpods.gen3"                            // AirPods (3rd generation)
            case 0x2019, 0x201B: return "airpods.gen4"                    // AirPods 4, with and without ANC
            case 0x200E, 0x2014, 0x2024, 0x2027: return "airpods.pro"     // AirPods Pro, every generation
            case 0x200A, 0x201F: return "airpods.max"                     // AirPods Max (Lightning, USB-C)
            case 0x200B: return "beats.powerbeats.pro"
            case 0x201D: return "beats.powerbeats.pro.2"
            case 0x2011: return "beats.studiobuds"
            case 0x2016: return "beats.studiobuds.plus"
            case 0x2012: return "beats.fitpro"
            default: break
            }
            let n = name.lowercased()
            if n.contains("max") { return "airpods.max" }
            if n.contains("pro") && n.contains("airpods") { return "airpods.pro" }
            if n.contains("powerbeats") { return "beats.powerbeats.pro" }
            if n.contains("studio buds") { return "beats.studiobuds" }
            if n.contains("beats") { return "beats.headphones" }
            if n.contains("airpods") { return "airpods.gen4" }
            return "headphones"
        }

        var icon: String {
            switch kind {
            case .headphones: Self.headphoneSymbol(productID: productID, name: name)
            case .mouse: "magicmouse.fill"
            case .keyboard: "keyboard.fill"
            case .trackpad: "rectangle.and.hand.point.up.left.fill"
            case .gamepad: "gamecontroller.fill"
            case .other: "dot.radiowaves.left.and.right"
            }
        }
    }

    @Published private(set) var devices: [Device] = []
    private var timer: Timer?
    private var alerted: Set<String> = []

    private init() {}

    func start() {
        refresh()
        let t = Timer(timeInterval: 90, repeats: true) { _ in MainActor.assumeIsolated { DeviceBatteries.shared.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The device closest to empty, for the live activity.
    var lowest: Device? { devices.filter { $0.level != nil }.min { ($0.level ?? 100) < ($1.level ?? 100) } }

    func refresh() {
        Task {
            async let bluetooth = Self.bluetoothDevices()
            async let hid = Self.hidDevices()
            var found = await bluetooth
            // Magic accessories report through IOKit too; fill in what system_profiler left out.
            for device in await hid where !found.contains(where: { $0.name == device.name }) { found.append(device) }
            found.sort { $0.name < $1.name }
            if found != devices { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { devices = found } }
            alertIfLow(found)
        }
    }

    private func alertIfLow(_ devices: [Device]) {
        for device in devices {
            guard let level = device.level else { continue }
            if level > 25 { alerted.remove(device.id); continue }
            guard level <= 20, AppSettings.shared.deviceBatteryAlerts, AppSettings.shared.toolsEnabled, !alerted.contains(device.id) else { continue }
            alerted.insert(device.id)
            ActivityCenter.shared.show(.notice(title: "\(device.name) · \(level)%", detail: "Battery low", icon: device.icon, tone: .warning), for: 5)
        }
    }

    nonisolated private static func percent(_ value: Any?) -> Int? {
        guard let s = value as? String else { return (value as? NSNumber)?.intValue }
        return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }

    nonisolated private static func bluetoothDevices() async -> [Device] {
        let result = await Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 15)
        guard let data = result.out.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [Device] = []
        for controller in controllers {
            // Only connected devices: disconnected ones keep their last-known levels, which would mislead.
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let main = percent(info["device_batteryLevelMain"]) ?? percent(info["device_batteryLevel"])
                    let left = percent(info["device_batteryLevelLeft"]), right = percent(info["device_batteryLevelRight"])
                    guard main != nil || left != nil || right != nil else { continue }
                    let minor = (info["device_minorType"] as? String ?? "").lowercased()
                    let kind: Device.Kind = minor.contains("headphone") || minor.contains("headset") || left != nil ? .headphones
                        : minor.contains("mouse") ? .mouse : minor.contains("keyboard") ? .keyboard
                        : minor.contains("trackpad") ? .trackpad : minor.contains("gamepad") || minor.contains("joystick") ? .gamepad : .other
                    let product = (info["device_productID"] as? String).flatMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
                    devices.append(Device(name: name, address: info["device_address"] as? String ?? "", kind: kind,
                                          main: main, left: left, right: right, caseLevel: percent(info["device_batteryLevelCase"]),
                                          productID: product))
                }
            }
        }
        return devices
    }

    nonisolated private static func hidDevices() async -> [Device] {
        let result = await Shell.run("/usr/sbin/ioreg", ["-r", "-a", "-k", "BatteryPercent"], timeout: 10)
        guard let data = result.out.data(using: .utf8), !data.isEmpty,
              let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let name = entry["Product"] as? String, let level = percent(entry["BatteryPercent"]) else { return nil }
            let lower = name.lowercased()
            let kind: Device.Kind = lower.contains("mouse") ? .mouse : lower.contains("keyboard") ? .keyboard
                : lower.contains("trackpad") ? .trackpad : .other
            return Device(name: name, address: entry["DeviceAddress"] as? String ?? "", kind: kind, main: level)
        }
    }
}

/// Whether the microphone or a camera is in use right now, and by which apps (microphone only:
/// macOS doesn't say which app has the camera).
@MainActor
final class PrivacyMonitor: ObservableObject {
    static let shared = PrivacyMonitor()

    struct UsingApp: Identifiable, Equatable {
        var id: String { bundleID ?? name }
        let name: String
        let bundleID: String?
        let bundlePath: String?
    }

    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false
    @Published private(set) var micApps: [UsingApp] = []

    private var timer: Timer?

    private init() {}

    var isActive: Bool { micInUse || cameraInUse }

    private var liveDemand = false

    func start() { update() }

    /// The live activity wants readings even when alerts are off.
    func setLiveDemand(_ wanted: Bool) {
        guard wanted != liveDemand else { return }
        liveDemand = wanted
        update()
    }

    /// Mic and camera alerts are one of Tools' switches.
    private static var alerts: Bool { AppSettings.shared.privacyAlerts && AppSettings.shared.toolsEnabled }

    func update() {
        let enabled = Self.alerts || liveDemand
        guard enabled != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard enabled else {
            micInUse = false
            cameraInUse = false
            micApps = []
            return
        }
        poll()
        let t = Timer(timeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { PrivacyMonitor.shared.poll() } }
        t.tolerance = 0.4 // lets macOS batch this wake-up with others
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let apps = Self.appsUsingMic()
        let mic = !apps.isEmpty
        let camera = Self.anyCameraRunning()
        if mic && !micInUse, Self.alerts {
            ActivityCenter.shared.show(.notice(title: "Microphone on", detail: apps.first?.name ?? "In use",
                                               icon: "mic.fill", tone: .info), for: 3)
        }
        if camera && !cameraInUse, Self.alerts {
            ActivityCenter.shared.show(.notice(title: "Camera on", detail: "In use", icon: "video.fill", tone: .info), for: 3)
        }
        if mic != micInUse || camera != cameraInUse || apps != micApps {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                micInUse = mic
                cameraInUse = camera
                micApps = apps
            }
        }
    }

    /// Processes with audio input running, grouped by the app responsible for them.
    static func appsUsingMic() -> [UsingApp] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioOutputManager.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        var seen = Set<String>()
        var apps: [UsingApp] = []
        for object in objects {
            guard (AudioOutputManager.property(object, kAudioProcessPropertyIsRunningInput) as UInt32?) == 1,
                  let pid: pid_t = AudioOutputManager.property(object, kAudioProcessPropertyPID), pid > 0 else { continue }
            let owner = AppIdentity.responsiblePID(for: pid)
            guard owner != own, pid != own else { continue }
            let identity = AppIdentity.of(pid: owner)
            // System helpers (Siri's "Hey Siri" listener, dictation) aren't worth flagging.
            if identity.bundleID?.hasPrefix("com.apple.") == true && identity.bundlePath?.hasPrefix("/System/Library/") == true { continue }
            let app = UsingApp(name: identity.name, bundleID: identity.bundleID, bundlePath: identity.bundlePath)
            if seen.insert(app.id).inserted { apps.append(app) }
        }
        return apps
    }

    nonisolated private static func anyCameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &devices) == noErr else { return false }
        for device in devices {
            var running: UInt32 = 0
            var runAddr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }
}
