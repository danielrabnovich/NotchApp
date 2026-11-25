import Foundation
import IOKit
import SwiftUI

/// What's plugged into each USB-C port: the cable's own chip (its e-marker, which says what it's
/// rated for), what's on the far end, the power they agreed on and how fast the data link came up.
///
/// It all comes from the IORegistry, no permission needed. The cable's chip is only read once
/// something on the far end starts a USB-PD conversation (a charger, a phone, a drive), so a cable
/// hanging loose says nothing. The chip is the maker's claim; the link is what really happened,
/// and the difference between the two is what's worth pointing out.
@MainActor
final class CableMonitor: ObservableObject {
    static let shared = CableMonitor()

    /// The cable's e-marker, decoded from its USB-PD identity (SOP′ Discover Identity).
    struct Cable: Equatable {
        let vendorID: Int
        let productID: Int
        /// USB-IF's certification number; 0 when it was never certified.
        let xid: Int
        let active: Bool
        /// USB's speed code: 0 USB 2, 1 USB 3 5 Gb/s, 2 10–20 Gb/s, 3 USB4 40 Gb/s, 4 USB4 80 Gb/s.
        let speed: Int
        let amps: Int
        let maxVolts: Int
        /// Extended Power Range: 48 V, the 140–240 W mode.
        let epr: Bool
        /// How long a signal takes through it, in roughly metres (passive cables only).
        let length: Int?
        /// The raw identity, to recognise this cable next time.
        let fingerprint: String

        var watts: Int { epr ? amps * 48 : amps * 20 }
        var certified: Bool { xid != 0 }
        var maker: String { CableMonitor.vendorName(vendorID) }
        var speedLabel: String { CableMonitor.speedLabel(speed) }
        var kind: String { active ? "Active cable" : "Passive cable" }
        var lengthLabel: String? {
            guard let length else { return nil }
            return length <= 1 ? "≤1 m" : length >= 8 ? ">7 m" : "~\(length) m"
        }
        /// "240 W · 40 Gb/s".
        var headline: String { "\(watts) W · \(speedLabel)" }
    }

    /// What's on the far end.
    struct Partner: Equatable {
        let name: String
        let vendorID: Int?
        /// Its fastest USB, in the same code as the cable's, when it says.
        let speed: Int?
        let isCharger: Bool
    }

    /// The data link that actually came up.
    enum Link: Equatable {
        case usb2
        case usb3(bitsPerSecond: Double?)
        case usb4(bitsPerSecond: Double?)

        var code: Int {
            switch self {
            case .usb2: 0
            case .usb3(let bps): (bps ?? 5e9) > 5.5e9 ? 2 : 1
            case .usb4(let bps): (bps ?? 40e9) > 45e9 ? 4 : (bps ?? 40e9) > 25e9 ? 3 : 2
            }
        }

        var label: String {
            switch self {
            case .usb2: "480 Mb/s"
            case .usb3(let bps): bps.map(CableMonitor.rate) ?? "USB 3"
            case .usb4(let bps): bps.map(CableMonitor.rate) ?? "USB4"
            }
        }

        var kind: String {
            switch self {
            case .usb2: "USB 2"
            case .usb3: "USB 3"
            case .usb4: "USB4 / Thunderbolt"
            }
        }
    }

    struct Power: Equatable {
        let millivolts: Int
        let milliamps: Int
        var watts: Int { Int((Double(millivolts) * Double(milliamps) / 1_000_000).rounded()) }
        var label: String { "\(watts) W" }
        var detail: String { String(format: "%g V × %g A", Double(millivolts) / 1000, (Double(milliamps) / 100).rounded() / 10) }
    }

    struct Port: Identifiable, Equatable {
        let id: String
        let number: Int
        var cable: Cable?
        var partner: Partner?
        var power: Power?
        var link: Link?
        /// The Mac set up USB4 / Thunderbolt and it never came up (what's left is USB 2).
        var usb4Failed = false
        /// Something on the far end has talked USB-PD, so a missing chip means the cable has none.
        var talkedPD = false

        var name: String { "Port \(number)" }

        /// The link it should have reached: the slower of what the cable and the device claim.
        var expectedLinkCode: Int? {
            guard let cable, let speed = partner?.speed else { return nil }
            return min(cable.speed, speed)
        }

        /// The link came up slower than both ends say they can go.
        var slowLink: Bool {
            guard let link, let expected = expectedLinkCode else { return usb4Failed }
            return usb4Failed || link.code < expected
        }
    }

    /// The USB-C ports with something plugged in, in port order.
    @Published private(set) var ports: [Port] = []

    private var entries: [(number: Int, id: String, entry: io_registry_entry_t)] = []
    private var plugEvents: [String: Int] = [:]
    private var pluggedAt: [String: Date] = [:]
    private var timer: Timer?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        entries = Self.findPorts()
        for port in entries { plugEvents[port.id] = Self.int(port.entry, "Plug Event Count") }
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { CableMonitor.shared.tick() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Cheap while nothing's plugged in (one number per port); a full read while something is,
    /// since the link and the power settle over the first few seconds.
    private func tick() {
        var plugged = false
        for port in entries {
            let events = Self.int(port.entry, "Plug Event Count")
            if events != plugEvents[port.id] {
                plugEvents[port.id] = events
                plugged = true
                pluggedAt[port.id] = Date()
                // A new plug: tell about it once the cable has been read and the link is up.
                let id = port.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { CableMonitor.shared.announce(id) }
            }
        }
        if plugged || !ports.isEmpty { refresh() }
    }

    func refresh() {
        let found = entries.compactMap { Self.read(number: $0.number, id: $0.id, entry: $0.entry, since: pluggedAt[$0.id]) }
        if found != ports { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { ports = found } }
    }

    // MARK: - Banner

    private static let seenKey = "cables.seen"

    /// A Banner for a cable the Mac hasn't seen before, or one whose link came up short. The same
    /// charging cable plugged in every morning stays quiet.
    private func announce(_ id: String) {
        refresh()
        guard AppSettings.shared.toolsEnabled, let port = ports.first(where: { $0.id == id }) else { return }
        let fingerprint = port.cable?.fingerprint ?? (port.talkedPD ? "basic" : nil)
        guard let fingerprint else { return }
        var seen = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
        let isNew = !seen.contains(fingerprint)
        guard isNew || port.slowLink else { return }
        if isNew {
            seen.append(fingerprint)
            UserDefaults.standard.set(Array(seen.suffix(60)), forKey: Self.seenKey)
        }
        let text = Self.banner(port)
        ActivityCenter.shared.show(.notice(title: text.title, detail: text.detail, icon: "cable.connector",
                                           tone: port.slowLink ? .warning : .info), for: 6) {
            CommandCenter.shared.show(.tools, pane: ToolsPane.cables.rawValue)
        }
    }

    static func banner(_ port: Port) -> (title: String, detail: String) {
        let title = port.cable.map { "\($0.headline) cable" } ?? "Basic USB-C cable"
        return (title, verdict(port))
    }

    /// One line on how it's doing, the most useful thing first.
    static func verdict(_ port: Port) -> String {
        let device = port.partner.map { $0.isCharger ? "Charger" : $0.name } ?? "Device"
        if port.usb4Failed { return "\(device) at \(port.link?.label ?? "480 Mb/s") · USB4 didn't come up" }
        if let link = port.link, let expected = port.expectedLinkCode, link.code < expected {
            return "\(device) at \(link.label) · both ends can do \(speedLabel(expected))"
        }
        if let link = port.link {
            let top = port.partner?.speed.map { link.code >= $0 } == true ? ", its top speed" : ""
            return "\(device) at \(link.label)\(top)" + (port.power.map { " · \($0.label)" } ?? "")
        }
        if let power = port.power { return "Charging at \(power.label)" }
        if port.cable == nil { return "Up to 60 W · USB 2 speed" }
        return "Rated \(port.cable!.amps) A up to \(port.cable!.maxVolts) V"
    }

    // MARK: - Reading the registry

    /// The built-in USB-C ports. They never change, so they're found once.
    nonisolated private static func findPorts() -> [(number: Int, id: String, entry: io_registry_entry_t)] {
        let match = IOServiceMatching("IOService") as NSMutableDictionary
        match["IOPropertyMatch"] = ["PortTypeDescription": "USB-C"]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [(Int, String, io_registry_entry_t)] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let id = string(entry, "PortDescription") ?? "Port-USB-C@\(found.count + 1)"
            found.append((int(entry, "PortNumber") ?? found.count + 1, id, entry)) // kept for the app's life
        }
        return found.sorted { $0.0 < $1.0 }
    }

    nonisolated private static func read(number: Int, id: String, entry: io_registry_entry_t, since: Date?) -> Port? {
        guard bool(entry, "ConnectionActive") else { return nil }
        var port = Port(id: id, number: number)
        let active = strings(entry, "TransportsActive")
        let provisioned = strings(entry, "TransportsProvisioned")
        var usbDevice: [String: Any]?
        var partnerVDOs: [UInt32] = []
        var partnerVendor: Int?

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return port }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            switch className(child) {
            case "IOPortTransportComponentCCUSBPDSOPp":
                if let meta = dict(child, "Metadata"), let vdos = vdos(meta) { port.cable = cable(meta, vdos) }
            case "IOPortTransportComponentCCUSBPDSOP":
                if let meta = dict(child, "Metadata") {
                    port.talkedPD = true
                    partnerVDOs = vdos(meta) ?? []
                    partnerVendor = meta["Vendor ID"] as? Int
                }
            case "IOPortTransportStateUSB3", "IOPortTransportStateUSB2":
                if usbDevice == nil, let meta = dict(child, "Metadata"), meta["Product"] != nil { usbDevice = meta }
            case "IOPortFeaturePowerSource":
                if let win = dict(child, "WinningPowerSourceOption"),
                   let mv = win["Voltage (mV)"] as? Int, let ma = win["Max Current (mA)"] as? Int {
                    port.power = Power(millivolts: mv, milliamps: ma)
                    port.talkedPD = true
                }
            default: break
            }
        }

        // The link: USB4 / Thunderbolt, else USB 3 at the device's speed, else USB 2.
        if active.contains("CIO") {
            port.link = .usb4(bitsPerSecond: nil)
        } else if active.contains("USB3") {
            port.link = .usb3(bitsPerSecond: (usbDevice?["Serial Number"] as? String).flatMap { linkSpeed(serial: $0) })
        } else if active.contains("USB2") {
            port.link = .usb2
        }
        // Training takes a moment; only call USB4 failed once it's had time to come up.
        let settled = since.map { Date().timeIntervalSince($0) > 6 } ?? true
        port.usb4Failed = settled && provisioned.contains("CIO") && !active.contains("CIO")

        // The far end: a USB device by its name, a charger by the power it gave, else whatever
        // its PD identity says.
        let header = partnerVDOs.first ?? 0
        let ufpType = Int((header >> 27) & 0x7) // 1 hub, 2 peripheral
        var speed: Int?
        if (ufpType == 1 || ufpType == 2), partnerVDOs.count >= 4 {
            let ufp = partnerVDOs[3]
            // USB4, USB 3 and USB 2 capability bits; the speed field is only meant for what's there.
            if (ufp >> 24) & 0xF != 0 { speed = Int(ufp & 0x7) }
        }
        if let usbDevice, let name = usbDevice["Product"] as? String {
            port.partner = Partner(name: name, vendorID: usbDevice["Vendor ID"] as? Int ?? partnerVendor, speed: speed, isCharger: false)
        } else if port.power != nil {
            port.partner = Partner(name: "Charger", vendorID: partnerVendor, speed: nil, isCharger: true)
        } else if port.talkedPD {
            port.partner = Partner(name: partnerVendor == 0x05AC ? "Apple device" : "Device", vendorID: partnerVendor, speed: speed, isCharger: false)
        }
        return port
    }

    /// Decodes the cable's identity: ID header, cert stat, product, then the cable VDO
    /// (USB PD 3.x, §6.4.4.3.1.6–7).
    nonisolated private static func cable(_ meta: [String: Any], _ vdos: [UInt32]) -> Cable? {
        guard vdos.count >= 4 else { return nil }
        let header = vdos[0], vdo = vdos[3]
        let type = Int((header >> 27) & 0x7) // 3 passive, 4 active
        let active = type == 4
        let current = Int((vdo >> 5) & 0x3)
        let volts = [20, 30, 40, 50][Int((vdo >> 9) & 0x3)]
        let latency = Int((vdo >> 13) & 0xF)
        return Cable(vendorID: meta["Vendor ID"] as? Int ?? Int(header & 0xFFFF),
                     productID: meta["Product ID"] as? Int ?? 0,
                     xid: Int(vdos[1]),
                     active: active,
                     speed: Int(vdo & 0x7),
                     amps: current == 2 ? 5 : 3,
                     maxVolts: volts,
                     epr: (vdo >> 17) & 1 == 1,
                     length: active || latency == 0 ? nil : latency,
                     fingerprint: vdos.map { String(format: "%08x", $0) }.joined(separator: "-"))
    }

    /// The link speed of the USB device with this serial number.
    nonisolated private static func linkSpeed(serial: String) -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            if string(device, "USB Serial Number") == serial, let speed = number(device, "UsbLinkSpeed") { return speed }
        }
        return nil
    }

    // MARK: - Registry helpers

    nonisolated private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    nonisolated private static func int(_ entry: io_registry_entry_t, _ key: String) -> Int? { property(entry, key) as? Int }
    nonisolated private static func number(_ entry: io_registry_entry_t, _ key: String) -> Double? { (property(entry, key) as? NSNumber)?.doubleValue }
    nonisolated private static func bool(_ entry: io_registry_entry_t, _ key: String) -> Bool { property(entry, key) as? Bool ?? false }
    nonisolated private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? { property(entry, key) as? String }
    nonisolated private static func strings(_ entry: io_registry_entry_t, _ key: String) -> [String] { property(entry, key) as? [String] ?? [] }
    nonisolated private static func dict(_ entry: io_registry_entry_t, _ key: String) -> [String: Any]? {
        guard let d = property(entry, key) as? [String: Any], !d.isEmpty else { return nil }
        return d
    }

    nonisolated private static func className(_ entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &name)
        return String(cString: name)
    }

    /// The VDOs, each four little-endian bytes.
    nonisolated private static func vdos(_ meta: [String: Any]) -> [UInt32]? {
        guard let list = meta["VDOs"] as? [Data], !list.isEmpty else { return nil }
        return list.map { data in
            data.count >= 4 ? data.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } : 0
        }
    }

    // MARK: - Words

    nonisolated static func speedLabel(_ code: Int) -> String {
        switch code {
        case 0: "USB 2"
        case 1: "5 Gb/s"
        case 2: "20 Gb/s"
        case 3: "40 Gb/s"
        case 4: "80 Gb/s"
        default: "Unknown speed"
        }
    }

    nonisolated static func speedDetail(_ code: Int) -> String {
        switch code {
        case 0: "USB 2 · 480 Mb/s"
        case 1: "USB 3 · 5 Gb/s"
        case 2: "USB 3 / USB4 · 10–20 Gb/s"
        case 3: "USB4 / Thunderbolt · 40 Gb/s"
        case 4: "USB4 v2 / Thunderbolt 5 · 80 Gb/s"
        default: "Unknown"
        }
    }

    nonisolated static func rate(_ bps: Double) -> String {
        bps >= 1e9 ? "\(Int((bps / 1e9).rounded())) Gb/s" : "\(Int((bps / 1e6).rounded())) Mb/s"
    }

    /// The few makers worth naming; the rest by their USB vendor ID.
    nonisolated static func vendorName(_ id: Int) -> String {
        switch id {
        case 0x05AC: "Apple"
        case 0x8087: "Intel"
        case 0x2109: "VIA Labs"
        case 0x04E8: "Samsung"
        case 0x18D1: "Google"
        case 0x291A: "Anker"
        case 0x050D: "Belkin"
        default: String(format: "Vendor 0x%04X", id)
        }
    }
}
