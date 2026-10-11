import AppKit
import Darwin
import IOKit
import IOKit.ps

// Low-level readers for SystemMonitor. None of these are main-actor bound; they are only
// ever touched from SystemMonitor's sampling queue.

// MARK: - SMC (temperatures, fans, system power)

/// Read-only client for the System Management Controller. Works unprivileged on Apple Silicon.
final class SMCReader {
    private struct KeyData {
        var key: UInt32 = 0
        var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt16(0))
        var pLimit = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        // Swift lays out by size, not stride, so pad keyInfo to match the C struct.
        var pad = (UInt8(0), UInt8(0), UInt8(0))
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private enum Selector: UInt8 { case read = 5, keyAtIndex = 8, keyInfo = 9 }

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connection) }

    /// Every key the SMC knows about (a few thousand on recent Macs).
    func allKeys() -> [String] {
        guard let count = value("#KEY").map({ Int($0) }), count > 0 else { return [] }
        return (0..<count).compactMap { i in
            var input = KeyData()
            input.data8 = Selector.keyAtIndex.rawValue
            input.data32 = UInt32(i)
            guard let out = call(&input), out.result == 0 else { return nil }
            return Self.string(out.key)
        }
    }

    /// Decodes the common numeric SMC types.
    func value(_ key: String) -> Double? {
        let code = Self.code(key)
        guard let info = info(code) else { return nil }
        var input = KeyData()
        input.key = code
        input.dataSize = info.size
        input.data8 = Selector.read.rawValue
        guard let out = call(&input), out.result == 0 else { return nil }
        return withUnsafeBytes(of: out.bytes) { b -> Double? in
            switch Self.string(info.type) {
            case "flt ": Double(b.load(as: Float.self))
            case "ui8 ": Double(b[0])
            case "ui16": Double(UInt16(b[0]) << 8 | UInt16(b[1]))
            case "ui32": Double(UInt32(bigEndian: b.loadUnaligned(as: UInt32.self)))
            case "sp78": Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
            case "fpe2": Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
            default: nil
            }
        }
    }

    private func info(_ code: UInt32) -> (size: UInt32, type: UInt32)? {
        if let cached = infoCache[code] { return cached }
        var input = KeyData()
        input.key = code
        input.data8 = Selector.keyInfo.rawValue
        guard let out = call(&input), out.result == 0 else { return nil }
        let info = (out.dataSize, out.dataType)
        infoCache[code] = info
        return info
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return r == kIOReturnSuccess ? output : nil
    }

    private static func code(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
    private static func string(_ c: UInt32) -> String {
        String(bytes: withUnsafeBytes(of: c.bigEndian, Array.init), encoding: .ascii) ?? ""
    }
}

// MARK: - IOReport (per-component energy)

@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFMutableDictionary>?
@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(_ a: UnsafeRawPointer?, _ channels: CFMutableDictionary, _ out: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, _ b: UInt64, _ c: CFTypeRef?) -> OpaquePointer?
@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(_ sub: OpaquePointer, _ channels: CFMutableDictionary, _ a: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(_ a: CFDictionary, _ b: CFDictionary, _ c: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ item: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ item: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ item: CFDictionary, _ a: Int32) -> Int64

/// Turns the "Energy Model" counters into watts between consecutive samples.
final class EnergyReader {
    private let channels: CFMutableDictionary
    private let subscription: OpaquePointer
    private var last: (sample: CFDictionary, time: TimeInterval)?

    init?() {
        guard let ch = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return nil }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, ch, &subbed, 0, nil) else { return nil }
        // Sample with the channels the subscription hands back, not the ones asked for: with the
        // latter, only some channels report (here only the GPU; CPU, memory and display read 0).
        channels = subbed?.takeRetainedValue() ?? ch
        subscription = sub
    }

    /// Watts for every channel since the previous call, by channel name (empty on the first call).
    func sampleAll() -> [String: Double] {
        guard let now = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue() else { return [:] }
        let time = ProcessInfo.processInfo.systemUptime
        defer { last = (now, time) }
        guard let last, time - last.time > 0.05,
              let delta = IOReportCreateSamplesDelta(last.sample, now, nil)?.takeRetainedValue() as? [String: Any],
              let items = delta["IOReportChannels"] as? [CFDictionary] else { return [:] }
        let dt = time - last.time
        var out: [String: Double] = [:]
        for item in items {
            guard let name = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String? else { continue }
            let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as String? ?? "mJ"
            let scale: Double = switch unit { case "nJ": 1e-9; case "uJ": 1e-6; default: 1e-3 }
            let raw = IOReportSimpleGetIntegerValue(item, 0)
            guard raw > 0 else { continue }
            out[name, default: 0] += Double(raw) * scale / dt
        }
        return out
    }

    /// Watts for the CPU and GPU since the previous call (nil on the first call or if not reported).
    func sample() -> (cpu: Double?, gpu: Double?) {
        guard let now = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue() else { return (nil, nil) }
        let time = ProcessInfo.processInfo.systemUptime
        defer { last = (now, time) }
        guard let last, time - last.time > 0.05,
              let delta = IOReportCreateSamplesDelta(last.sample, now, nil)?.takeRetainedValue() as? [String: Any],
              let items = delta["IOReportChannels"] as? [CFDictionary] else { return (nil, nil) }

        var cpu: Double?, gpu: Double?
        let dt = time - last.time
        for item in items {
            guard let name = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String?,
                  name == "CPU Energy" || name == "GPU Energy" else { continue }
            let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as String? ?? "mJ"
            let scale: Double = switch unit { case "nJ": 1e-9; case "uJ": 1e-6; default: 1e-3 }
            let raw = IOReportSimpleGetIntegerValue(item, 0)
            guard raw > 0 else { continue }
            let watts = Double(raw) * scale / dt
            if name == "CPU Energy" { cpu = watts } else { gpu = watts }
        }
        return (cpu, gpu)
    }
}

// MARK: - CPU load

final class CPULoadReader {
    private var previous: [(user: UInt64, system: UInt64, idle: UInt64)] = []

    /// Per-core (user, system) fractions since the previous call.
    func sample() -> [(user: Double, system: Double)] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        let ticks = (0..<Int(count)).map { i -> (user: UInt64, system: UInt64, idle: UInt64) in
            func t(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[i * stride + Int(state)])) }
            return (t(CPU_STATE_USER) + t(CPU_STATE_NICE), t(CPU_STATE_SYSTEM), t(CPU_STATE_IDLE))
        }
        defer { previous = ticks }
        guard previous.count == ticks.count else { return ticks.map { _ in (0, 0) } }
        return zip(ticks, previous).map { (now, old) -> (user: Double, system: Double) in
            let user = Double(now.user &- old.user)
            let system = Double(now.system &- old.system)
            let total = user + system + Double(now.idle &- old.idle)
            return total > 0 ? (user / total, system / total) : (0, 0)
        }
    }

    /// Whether each logical core belongs to the fastest cluster ("P" on M1–M4, "Super" on M5).
    static func performanceCores() -> [Bool] {
        var result: [Int: Bool] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPlatformDevice"), &iterator) == kIOReturnSuccess else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let cluster = IORegistryEntryCreateCFProperty(entry, "cluster-type" as CFString, nil, 0)?.takeRetainedValue() as? Data,
                  let id = IORegistryEntryCreateCFProperty(entry, "logical-cpu-id" as CFString, nil, 0)?.takeRetainedValue() as? Int
            else { continue }
            result[id] = cluster.first == UInt8(ascii: "P")
        }
        return (0..<result.count).map { result[$0] ?? false }
    }
}

// MARK: - Memory

struct MemoryReading {
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// File-backed pages the system can drop at any time.
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    /// 1 normal, 2 warning, 4 critical.
    var pressure: Int = 1
    var used: UInt64 { app + wired + compressed }
}

enum MemoryReader {
    /// Same breakdown Activity Monitor uses.
    static func sample() -> MemoryReading {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size) }
        }
        var m = MemoryReading()
        guard r == KERN_SUCCESS else { return m }
        let page = UInt64(vm_kernel_page_size)
        m.app = UInt64(stats.internal_page_count &- stats.purgeable_count) * page
        m.wired = UInt64(stats.wire_count) * page
        m.compressed = UInt64(stats.compressor_page_count) * page
        m.cached = UInt64(stats.external_page_count) * page
        var swap = xsw_usage()
        var swapLen = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapLen, nil, 0) == 0 { m.swapUsed = swap.xsu_used }
        var level: Int32 = 1
        var len = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, nil, 0) == 0 { m.pressure = Int(level) }
        return m
    }
}

// MARK: - GPU

struct GPUReading {
    var usage: Double
    var renderer: Double
    var tiler: Double
    var memory: UInt64?
}

enum GPUReader {
    /// Utilisation (0…1) and memory in use, from the first accelerator that reports them.
    static func sample() -> GPUReading? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, nil, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let usage = stats["Device Utilization %"] as? Int else { continue }
            let memory = (stats["In use system memory"] as? Int).map { UInt64($0) }
            return GPUReading(usage: Double(usage) / 100,
                              renderer: Double(stats["Renderer Utilization %"] as? Int ?? 0) / 100,
                              tiler: Double(stats["Tiler Utilization %"] as? Int ?? 0) / 100,
                              memory: memory)
        }
        return nil
    }

    /// Chip name and GPU core count; these never change, so read them once.
    static func info() -> (model: String?, cores: Int?) {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard entry != 0 else { return (nil, nil) }
        defer { IOObjectRelease(entry) }
        let model = IORegistryEntryCreateCFProperty(entry, "model" as CFString, nil, 0)?.takeRetainedValue() as? String
        let cores = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, nil, 0)?.takeRetainedValue() as? Int
        return (model, cores)
    }
}

// MARK: - Battery power

struct BatteryPowerReading {
    /// Watts flowing into (+) or out of (−) the battery.
    var battery: Double
    /// Whole-system draw as measured by the power controller.
    var systemLoad: Double?
    var adapterWatts: Int?
    var minutesRemaining: Int?
    /// Full-charge capacity as a share of the design capacity, like System Settings shows.
    var health: Double?
    var cycles: Int?
}

enum BatteryPowerReader {
    static func sample() -> BatteryPowerReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func prop<T>(_ key: String) -> T? { IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue() as? T }
        guard let mv: Int = prop("Voltage"), let ma: Int = prop("InstantAmperage") ?? prop("Amperage") else { return nil }
        let external: Bool = prop("ExternalConnected") ?? false
        let adapter: [String: Any]? = prop("AdapterDetails")
        let telemetry: [String: Any]? = prop("PowerTelemetryData")
        let load = (telemetry?["SystemLoad"] as? Int).flatMap { $0 > 0 ? Double($0) / 1000 : nil }
        let remaining = IOPSGetTimeRemainingEstimate()
        let data: [String: Any]? = prop("BatteryData")
        let health: Double? = {
            guard let design = data?["DesignCapacity"] as? Int, design > 0,
                  let full = data?["NominalChargeCapacity"] as? Int ?? data?["AppleRawMaxCapacity"] as? Int else { return nil }
            return min(1, Double(full) / Double(design))
        }()
        return BatteryPowerReading(battery: Double(mv) * Double(ma) / 1_000_000,
                                   systemLoad: load,
                                   adapterWatts: external ? adapter?["Watts"] as? Int : nil,
                                   minutesRemaining: remaining > 0 ? Int(remaining / 60) : nil,
                                   health: health,
                                   cycles: prop("CycleCount"))
    }
}

// MARK: - Processes

struct AppUsage: Identifiable, Equatable {
    /// The responsible (parent app) pid that helpers are grouped under.
    var pid: pid_t
    var name: String
    /// The .app bundle this process lives in, for its icon.
    var bundlePath: String?
    /// Share of one core, like Activity Monitor (can exceed 1).
    var cpu: Double
    var memory: UInt64
    var id: pid_t { pid }
}

/// Per-app CPU and memory, with helper processes folded into the app that owns them.
/// Only the user's own processes are readable without root, which is what matters here.
final class ProcessReader {
    private var previous: [pid_t: UInt64] = [:]
    private var lastTime: UInt64 = 0
    private let ticksToNanos: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    func sample() -> [AppUsage] {
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = Int(proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size)))

        let now = mach_absolute_time()
        let elapsed = Double(now &- lastTime) * ticksToNanos
        let hasBaseline = lastTime != 0 && elapsed > 0
        var times: [pid_t: UInt64] = [:]
        var apps: [pid_t: AppUsage] = [:]

        for pid in pids.prefix(count) where pid > 0 {
            var info = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard r == 0 else { continue }
            let cpuTime = info.ri_user_time + info.ri_system_time
            times[pid] = cpuTime
            let delta = hasBaseline ? Double(cpuTime &- (previous[pid] ?? cpuTime)) * ticksToNanos / elapsed : 0

            let key = AppIdentity.responsiblePID(for: pid)
            var app = apps[key] ?? {
                let identity = AppIdentity.of(pid: key)
                return AppUsage(pid: key, name: identity.name, bundlePath: identity.bundlePath, cpu: 0, memory: 0)
            }()
            app.cpu += max(0, delta)
            app.memory += info.ri_phys_footprint
            apps[key] = app
        }
        previous = times
        lastTime = now
        AppIdentity.prune(keeping: Set(times.keys))
        return Array(apps.values)
    }
}
