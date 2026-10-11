import Combine
import Foundation

/// One reading of every sensor.
struct SystemSnapshot {
    var cpuUser = 0.0
    var cpuSystem = 0.0
    var cores: [Double] = []
    var cpuTemp: Double?
    var cpuTempMax: Double?
    var cpuPower: Double?
    var loadAverage: [Double] = []

    var gpu: Double?
    var gpuMemory: UInt64?
    var gpuRenderer: Double?
    var gpuTiler: Double?
    var gpuTemp: Double?
    var gpuTempMax: Double?
    var gpuPower: Double?

    var memory = MemoryReading()

    var systemPower: Double?
    var batteryPower: Double?
    var adapterWatts: Int?
    var batteryMinutesRemaining: Int?
    var batteryHealth: Double?
    var batteryCycles: Int?
    var batteryTemp: Double?
    var fans: [Double] = []
    var fanMax: [Double] = []

    /// Per-app usage; only filled while a card's detail side is showing.
    var topCPU: [AppUsage] = []
    var topMemory: [AppUsage] = []

    var cpuTotal: Double { cpuUser + cpuSystem }
}

/// Samples CPU, GPU, memory, temperatures, fans and power for the Stats tab.
/// Ticks quickly while a stats view is on screen and slowly otherwise, so the graphs
/// already have history when the notch opens.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    static let historyLength = 48

    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var cpuSystemHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var powerHistory: [Double] = []
    /// Debug hook: "<card>#<nonce>" expands that card (anything else collapses).
    @Published var debugExpand = ""

    /// Asks the Stats tab to open a card (a Glance was clicked); it picks this up as it appears.
    func requestCard(_ kind: StatKind) {
        debugExpand = "\(kind.rawValue)#\(Date().timeIntervalSince1970)"
    }

    /// A card asked for in the last couple of seconds, if any.
    var pendingCard: StatKind? {
        let parts = debugExpand.split(separator: "#")
        guard parts.count == 2, let at = Double(parts[1]), Date().timeIntervalSince1970 - at < 2 else { return nil }
        return StatKind(rawValue: String(parts[0]))
    }

    /// Whether each core is in the fastest cluster, for colouring the core bars.
    let performanceCores = CPULoadReader.performanceCores()
    /// Names of the fastest and other clusters, e.g. "Super" / "Performance" on M5, "Performance" / "Efficiency" before.
    let clusterNames: (fast: String, other: String) = (sysctlString("hw.perflevel0.name") ?? "Performance",
                                                       sysctlString("hw.perflevel1.name") ?? "Efficiency")
    let gpuInfo = GPUReader.info()

    private let queue = DispatchQueue(label: "com.notchapp.sensors", qos: .utility)
    private let sampler = Sampler()
    private var timer: DispatchSourceTimer?
    private var viewers = 0
    private var detailViewers = 0
    /// Stats are pinned beside the closed notch: keep sampling (every 2s) even with the Stats tab off.
    private var liveDemand = false
    private var cancellables = Set<AnyCancellable>()

    func start() {
        AppSettings.shared.$statsEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                DispatchQueue.main.async { self?.reschedule(enabled: enabled) }
            }
            .store(in: &cancellables)
    }

    func setLiveDemand(_ wanted: Bool) {
        guard wanted != liveDemand else { return }
        liveDemand = wanted
        reschedule(enabled: AppSettings.shared.statsEnabled)
    }

    func viewerAppeared() {
        viewers += 1
        if viewers == 1 { reschedule(enabled: AppSettings.shared.statsEnabled) }
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { reschedule(enabled: AppSettings.shared.statsEnabled) }
    }

    /// A card listing apps was expanded; per-app stats are only gathered while one is showing.
    func detailAppeared() {
        detailViewers += 1
        if detailViewers == 1 { reschedule(enabled: AppSettings.shared.statsEnabled) }
    }

    func detailDisappeared() {
        detailViewers = max(0, detailViewers - 1)
        if detailViewers == 0 { reschedule(enabled: AppSettings.shared.statsEnabled) }
    }

    private func reschedule(enabled: Bool) {
        timer?.cancel()
        timer = nil
        guard enabled || liveDemand else { return }
        // Nothing showing stats: a slow trickle that just keeps the graphs' history going.
        let interval: Double = viewers > 0 ? 1 : liveDemand ? 2 : 10
        let details = viewers > 0 && detailViewers > 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        t.setEventHandler { [sampler] in
            let s = sampler.sample(details: details)
            DispatchQueue.main.async { MainActor.assumeIsolated { SystemMonitor.shared.apply(s) } }
        }
        t.resume()
        timer = t
    }

    private func apply(_ s: SystemSnapshot) {
        snapshot = s
        push(&cpuHistory, s.cpuTotal)
        push(&cpuSystemHistory, s.cpuSystem)
        push(&gpuHistory, s.gpu ?? 0)
        push(&memoryHistory, s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : 0)
        if let power = s.systemPower { push(&powerHistory, power) }
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }
}

/// Owns the readers; only used on the monitor's serial queue.
private final class Sampler: @unchecked Sendable {
    private let cpu = CPULoadReader()
    private let smc = SMCReader()
    private let energy = EnergyReader()
    private let processes = ProcessReader()
    private lazy var keys = TemperatureKeys(smc: smc)

    init() {
        // Both readers report deltas, so take a baseline now to avoid a zero first sample.
        _ = cpu.sample()
        _ = energy?.sample()
    }

    func sample(details: Bool) -> SystemSnapshot {
        var s = SystemSnapshot()

        let cores = cpu.sample()
        s.cores = cores.map { $0.user + $0.system }
        if !cores.isEmpty {
            s.cpuUser = cores.map(\.user).reduce(0, +) / Double(cores.count)
            s.cpuSystem = cores.map(\.system).reduce(0, +) / Double(cores.count)
        }

        if let gpu = GPUReader.sample() {
            s.gpu = gpu.usage
            s.gpuRenderer = gpu.renderer
            s.gpuTiler = gpu.tiler
            s.gpuMemory = gpu.memory
        }
        s.memory = MemoryReader.sample()

        if let power = energy?.sample() {
            s.cpuPower = power.cpu
            s.gpuPower = power.gpu
        }
        let battery = BatteryPowerReader.sample()
        if let battery {
            s.batteryPower = battery.battery
            s.adapterWatts = battery.adapterWatts
            s.batteryMinutesRemaining = battery.minutesRemaining
            s.batteryHealth = battery.health
            s.batteryCycles = battery.cycles
        }

        if let smc {
            let cpuTemps = valid(keys.cpu.compactMap { smc.value($0) })
            let gpuTemps = valid(keys.gpu.compactMap { smc.value($0) })
            s.cpuTemp = average(cpuTemps)
            s.cpuTempMax = cpuTemps.max()
            s.gpuTemp = average(gpuTemps)
            s.gpuTempMax = gpuTemps.max()
            s.batteryTemp = smc.value("TB0T").flatMap { valid([$0]).first }
            s.systemPower = smc.value("PSTR")
            s.fans = keys.fans.compactMap { smc.value($0) }
            s.fanMax = keys.fanMax.compactMap { smc.value($0) }
        }

        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { s.loadAverage = load }

        if details {
            let apps = processes.sample()
            s.topCPU = Array(apps.filter { $0.cpu >= 0.005 }.sorted { $0.cpu > $1.cpu }.prefix(4))
            s.topMemory = Array(apps.sorted { $0.memory > $1.memory }.prefix(4))
        }
        // The battery controller's figure only refreshes every half minute or so; use it if the SMC has none.
        if s.systemPower == nil { s.systemPower = battery?.systemLoad }
        return s
    }

    /// Drops sensors that are idle or reporting garbage.
    private func valid(_ values: [Double]) -> [Double] { values.filter { $0 > 5 && $0 < 130 } }

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

/// SMC key names differ per chip, so discover them by prefix once.
private struct TemperatureKeys {
    var cpu: [String] = []
    var gpu: [String] = []
    var fans: [String] = []
    var fanMax: [String] = []

    init(smc: SMCReader?) {
        guard let smc else { return }
        let all = smc.allKeys()
        // Tp = performance-core die sensors, Te = efficiency cores, Tg = GPU.
        cpu = all.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }
        gpu = all.filter { $0.hasPrefix("Tg") }
        let fanCount = Int(smc.value("FNum") ?? 0)
        fans = (0..<fanCount).map { "F\($0)Ac" }
        fanMax = (0..<fanCount).map { "F\($0)Mx" }
    }
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}
