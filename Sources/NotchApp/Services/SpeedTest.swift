import Foundation
import SwiftUI

/// Internet speed test using macOS's own `networkQuality` (Apple's test servers; no account or
/// third-party service). The tool only reports at the end, so the live reading while it runs comes
/// from the Mac's own interface counters.
@MainActor
final class SpeedTest: ObservableObject {
    static let shared = SpeedTest()

    struct Result: Codable, Equatable, Identifiable {
        var id: Date { date }
        let date: Date
        let download: Double // bits per second
        let upload: Double
        /// Round trips per minute under load: Apple's "responsiveness" (higher is better).
        let responsiveness: Double?
        /// Idle latency in milliseconds.
        let latency: Double?
        let interface: String?

        var responsivenessLabel: String? {
            guard let rpm = responsiveness else { return nil }
            return rpm >= 1000 ? "High" : rpm >= 200 ? "Medium" : "Low"
        }
    }

    enum Phase: Equatable {
        case idle
        case connecting
        case download
        case upload
        case done(Result)
        case failed(String)

        var isRunning: Bool { [.connecting, .download, .upload].contains(self) }
    }

    @Published private(set) var phase: Phase = .idle
    /// Peak speeds seen live in each direction this run, in bits per second.
    @Published private(set) var liveDown: Double = 0
    @Published private(set) var liveUp: Double = 0
    @Published private(set) var history: [Result] = []

    private var process: Process?
    private var watcher: Timer?
    private let defaultsKey = "speedTestHistory"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([Result].self, from: data) {
            history = saved
        }
    }

    var last: Result? { history.first }

    func start() {
        guard !phase.isRunning else { return }
        liveDown = 0
        liveUp = 0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { phase = .connecting }
        let network = NetworkMonitor.shared
        network.setSpeedTestDemand(true)
        // Follow the counters each second; whichever way is busiest is the phase in progress.
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { SpeedTest.shared.follow() } }
        RunLoop.main.add(t, forMode: .common)
        watcher = t

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        // Sequential, so download and upload each get the whole link, and a hard cap on time.
        p.arguments = ["-c", "-s", "-M", "40"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        process = p
        p.terminationHandler = { proc in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor in SpeedTest.shared.finished(data: data, status: status, cancelled: reason == .uncaughtSignal) }
        }
        do {
            try p.run()
        } catch {
            finish(.failed("Couldn't start the speed test"))
        }
    }

    func cancel() {
        guard phase.isRunning else { return }
        process?.terminate()
    }

    func reset() {
        guard !phase.isRunning else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { phase = .idle }
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Live bits per second for the phase in progress.
    var liveSpeed: Double {
        let n = NetworkMonitor.shared
        return phase == .upload ? n.upRate * 8 : n.downRate * 8
    }

    private func follow() {
        let n = NetworkMonitor.shared
        let down = n.downRate * 8, up = n.upRate * 8
        liveDown = max(liveDown, down)
        liveUp = max(liveUp, up)
        // A megabit a second either way means the test is moving data.
        guard max(down, up) > 1_000_000 else { return }
        let next: Phase = up > down ? .upload : .download
        if next != phase, phase.isRunning {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { phase = next }
        }
    }

    private func finished(data: Data, status: Int32, cancelled: Bool) {
        if cancelled {
            finish(.idle)
            return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let down = (obj["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (obj["ul_throughput"] as? NSNumber)?.doubleValue else {
            finish(.failed(status == 0 ? "The test didn't return a result" : "Couldn't reach Apple's test servers"))
            return
        }
        let rpm = (obj["responsiveness"] as? NSNumber)?.doubleValue
            ?? (obj["dl_responsiveness"] as? NSNumber)?.doubleValue
        let result = Result(date: Date(), download: down, upload: up, responsiveness: rpm,
                            latency: (obj["base_rtt"] as? NSNumber)?.doubleValue,
                            interface: NetworkMonitor.shared.info.interfaceName.nilIfEmpty)
        history.insert(result, at: 0)
        if history.count > 12 { history.removeLast(history.count - 12) }
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        finish(.done(result))
        ActivityCenter.shared.show(.notice(title: "↓ \(formatMbps(down))  ↑ \(formatMbps(up)) Mbps",
                                           detail: "Speed test", icon: "speedometer"), for: 5)
    }

    private func finish(_ phase: Phase) {
        watcher?.invalidate()
        watcher = nil
        process = nil
        NetworkMonitor.shared.setSpeedTestDemand(false)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self.phase = phase }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
