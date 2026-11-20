import AppKit
import Combine
import IOKit

/// Each process's time on the GPU, from the GPU driver's own record of its clients (every app
/// that draws with Metal has one, the window server included). Readable without any permission.
enum GPUTimeReader {
    /// The driver's name for each process it has seen ("WindowServer"), for those an app can't
    /// look up itself (system processes run as root).
    nonisolated(unsafe) private(set) static var names: [pid_t: String] = [:]
    private static let lock = NSLock()

    static func name(of pid: pid_t) -> String? { lock.lock(); defer { lock.unlock() }; return names[pid] }

    /// Nanoseconds of GPU time so far, by process.
    static func sample() -> [pid_t: UInt64] {
        var out: [pid_t: UInt64] = [:]
        var seen: [pid_t: String] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iterator) }
        var accelerator = IOIteratorNext(iterator)
        while accelerator != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS {
                var child = IOIteratorNext(children)
                while child != 0 {
                    var props: Unmanaged<CFMutableDictionary>?
                    if IORegistryEntryCreateCFProperties(child, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                       let dict = props?.takeRetainedValue() as? [String: Any],
                       let creator = dict["IOUserClientCreator"] as? String,
                       let usage = dict["AppUsage"] as? [[String: Any]], !usage.isEmpty,
                       let pid = pid(from: creator) {
                        let time = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
                        out[pid, default: 0] += time
                        if let comma = creator.firstIndex(of: ",") {
                            seen[pid] = creator[creator.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                        }
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(iterator)
        }
        lock.lock(); names = seen; lock.unlock()
        return out
    }

    /// "pid 613, WindowServer" → 613.
    private static func pid(from creator: String) -> pid_t? {
        guard creator.hasPrefix("pid "), let comma = creator.firstIndex(of: ",") else { return nil }
        return pid_t(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma])
    }
}

/// Splits the GPU's measured power across apps by their share of its time since the last call.
final class GPUShare {
    private var previous: [pid_t: UInt64] = [:]

    /// Each app's share of the GPU's busy time (0…1, summing to 1), keyed by the app responsible.
    func sample() -> [pid_t: Double] {
        let now = GPUTimeReader.sample()
        defer { previous = now }
        guard !previous.isEmpty else { return [:] }
        var deltas: [pid_t: Double] = [:]
        for (pid, time) in now {
            let before = previous[pid] ?? time
            guard time > before else { continue }
            deltas[AppIdentity.responsiblePID(for: pid), default: 0] += Double(time - before)
        }
        let total = deltas.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return deltas.mapValues { $0 / total }
    }

    /// Adds each app's share of `gpuWatts` to its power, and lists the apps that only use the GPU
    /// (or whose processes can't be read, as the window server's can't) as apps of their own.
    static func attribute(_ shares: [pid_t: Double], gpuWatts: Double?, to apps: [AppUsage]) -> [AppUsage] {
        guard let gpuWatts, gpuWatts > 0, !shares.isEmpty else { return apps }
        var byPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for (pid, share) in shares {
            let watts = share * gpuWatts
            if byPID[pid] == nil {
                let identity = AppIdentity.of(pid: pid)
                let name = identity.name.hasPrefix("pid ") ? GPUTimeReader.name(of: pid) ?? identity.name : identity.name
                byPID[pid] = AppUsage(pid: pid, name: name, bundlePath: identity.bundlePath, cpu: 0, memory: 0)
            }
            byPID[pid]?.power += watts
            byPID[pid]?.gpuPower += watts
        }
        return Array(byPID.values)
    }
}

/// The last hour of each app's power (processor and GPU), a minute at a time, so the Power card can
/// say which apps warmed the Mac, not just who's busy this second. Both counters it reads add up
/// on their own, so one cheap reading a minute gives the exact energy in between; nothing polls
/// faster. Paused while nobody's there (locked, displays asleep).
@MainActor
final class PowerHistory: ObservableObject {
    static let shared = PowerHistory()

    struct Entry: Identifiable {
        let pid: pid_t
        let name: String
        let bundlePath: String?
        /// Average watts over the span asked for.
        let watts: Double
        var id: pid_t { pid }
    }

    /// Per-minute energy (joules) by app, oldest first; at most an hour of them.
    private var minutes: [[pid_t: Double]] = []
    private var names: [pid_t: (String, String?)] = [:]
    private let queue = DispatchQueue(label: "com.notchapp.powerhistory", qos: .utility)
    private let processes = ProcessReader()
    private let gpu = GPUShare()
    private let energy = EnergyReader()
    private var timer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        guard timer == nil else { return }
        AppSettings.shared.$statsEnabled.combineLatest(Presence.shared.$away)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] enabled, away in DispatchQueue.main.async { self?.schedule(enabled && !away) } }
            .store(in: &cancellables)
    }

    private func schedule(_ on: Bool) {
        timer?.cancel()
        timer = nil
        guard on else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 60, leeway: .seconds(10))
        var primed = false
        t.setEventHandler { [processes, gpu, energy] in
            let apps = processes.sample()
            let shares = gpu.sample()
            let gpuWatts = energy?.sample().gpu
            // The first reading after a pause only sets the baseline (its deltas span the pause).
            guard primed else { primed = true; return }
            let all = GPUShare.attribute(shares, gpuWatts: gpuWatts, to: apps)
            DispatchQueue.main.async { MainActor.assumeIsolated { PowerHistory.shared.add(all) } }
        }
        t.resume()
        timer = t
    }

    private func add(_ apps: [AppUsage]) {
        var minute: [pid_t: Double] = [:]
        for app in apps where app.power > 0.005 {
            minute[app.pid] = app.power * 60
            names[app.pid] = (app.name, app.bundlePath)
        }
        minutes.append(minute)
        if minutes.count > 60 { minutes.removeFirst(minutes.count - 60) }
        objectWillChange.send()
    }

    /// The apps that drew the most over the last `span` minutes (or as much of it as has been
    /// recorded), by their average watts across it.
    func top(minutes span: Int = 60, limit: Int = 5) -> [Entry] {
        let recent = minutes.suffix(span)
        guard !recent.isEmpty else { return [] }
        var joules: [pid_t: Double] = [:]
        for minute in recent { for (pid, j) in minute { joules[pid, default: 0] += j } }
        let seconds = Double(recent.count) * 60
        return joules.sorted { $0.value > $1.value }.prefix(limit).map { pid, j in
            Entry(pid: pid, name: names[pid]?.0 ?? "pid \(pid)", bundlePath: names[pid]?.1, watts: j / seconds)
        }
    }

    /// How many minutes are on record (up to 60).
    var span: Int { minutes.count }
}
