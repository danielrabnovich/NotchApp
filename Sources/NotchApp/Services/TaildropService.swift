import AppKit
import Combine

/// A device on the tailnet that can receive Taildrop files.
struct TailDevice: Identifiable, Equatable {
    let name: String
    let ip: String
    let os: String
    let online: Bool
    var id: String { ip }

    var icon: String {
        switch os.lowercased() {
        case "ios": name.lowercased().contains("ipad") ? "ipad" : "iphone"
        case "macos": "laptopcomputer"
        case "windows": "pc"
        case "android": "smartphone"
        case "tvos": "appletv"
        case "linux": "server.rack"
        default: "desktopcomputer"
        }
    }
}

/// Taildrop through the Tailscale CLI: send files to your devices, and pull incoming files
/// out of the Tailscale inbox into Downloads.
@MainActor
final class TaildropService: ObservableObject {
    static let shared = TaildropService()

    enum Status: Equatable { case notInstalled, stopped, ready }

    struct SendJob: Equatable {
        let device: TailDevice
        let fileCount: Int
        var progress: Double?
    }

    @Published private(set) var status: Status = .notInstalled
    @Published private(set) var devices: [TailDevice] = []
    /// Files waiting for a device to be picked.
    @Published var pending: [URL] = []
    @Published private(set) var sending: SendJob?

    private var receiveTimer: Timer?
    private var receiving = false
    private var cancellables = Set<AnyCancellable>()

    /// The CLI ships inside the Mac app; Homebrew installs it on the PATH.
    nonisolated static let cli: String? = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    func start() {
        let settings = AppSettings.shared
        settings.$taildropReceive.removeDuplicates()
            .sink { [weak self] on in DispatchQueue.main.async { self?.setReceiving(on) } }
            .store(in: &cancellables)
        refresh()
    }

    // MARK: - Devices

    /// Re-reads the device list (cheap; called when a picker opens).
    func refresh() {
        guard let cli = Self.cli else { status = .notInstalled; return }
        Task.detached {
            let targets = Self.run(cli, ["file", "cp", "--targets"])
            let statusJSON = Self.run(cli, ["status", "--json"])
            await MainActor.run { TaildropService.shared.apply(targets: targets, statusJSON: statusJSON) }
        }
    }

    private func apply(targets: (code: Int32, out: String), statusJSON: (code: Int32, out: String)) {
        guard targets.code == 0 else { status = .stopped; devices = []; return }
        status = .ready
        // OS per IP, for the device icons.
        var osByIP: [String: String] = [:]
        if let data = statusJSON.out.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let peers = obj["Peer"] as? [String: [String: Any]] {
            for peer in peers.values {
                let os = peer["OS"] as? String ?? ""
                for ip in peer["TailscaleIPs"] as? [String] ?? [] { osByIP[ip] = os }
            }
        }
        devices = targets.out.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t").map(String.init)
            guard cols.count >= 2 else { return nil }
            let offline = cols.count > 2 && cols[2].hasPrefix("offline")
            return TailDevice(name: cols[1], ip: cols[0], os: osByIP[cols[0]] ?? "", online: !offline)
        }
        .sorted { $0.online != $1.online ? $0.online : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Sending

    /// Queues files and opens the device picker.
    func offer(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending = urls
        refresh()
    }

    func send(to device: TailDevice) {
        guard let cli = Self.cli, !pending.isEmpty, sending == nil else { return }
        let files = pending
        pending = []
        sending = SendJob(device: device, fileCount: files.count, progress: nil)
        Task.detached {
            let result = Self.run(cli, ["file", "cp", "--update-interval", "200ms"] + files.map(\.path) + ["\(device.ip):"]) { chunk in
                // Progress lines look like "… 42.10%"; take the last percentage printed.
                guard let pct = Self.lastPercent(in: chunk) else { return }
                Task { @MainActor in TaildropService.shared.sending?.progress = pct / 100 }
            }
            await MainActor.run {
                let shared = TaildropService.shared
                shared.sending = nil
                let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
                if result.code == 0 {
                    ActivityCenter.shared.show(.taildrop(title: "Sent to \(device.name)", detail: what, received: false), for: 3.5)
                } else {
                    let reason = result.out.split(separator: "\n").last.map(String.init) ?? "Taildrop failed"
                    ActivityCenter.shared.show(.taildrop(title: "Couldn't send to \(device.name)", detail: reason, received: false), for: 5)
                }
            }
        }
    }

    func cancelPending() { pending = [] }

    // MARK: - Receiving

    private func setReceiving(_ on: Bool) {
        receiveTimer?.invalidate()
        receiveTimer = nil
        guard on, Self.cli != nil else { return }
        // A short-lived `file get` every few seconds rather than one long-running `--loop`
        // process, so nothing is left running if NotchApp is force-quit.
        let t = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { TaildropService.shared.collect() }
        }
        RunLoop.main.add(t, forMode: .common)
        receiveTimer = t
        collect()
    }

    private func collect() {
        guard !receiving, let cli = Self.cli else { return }
        receiving = true
        let downloads = DownloadsStore.shared.folder
        Task.detached {
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? [])
            _ = Self.run(cli, ["file", "get", "--conflict=rename", downloads.path])
            let after = Set((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? [])
            let arrived = after.subtracting(before).sorted().map { downloads.appendingPathComponent($0) }
            await MainActor.run {
                let shared = TaildropService.shared
                shared.receiving = false
                guard !arrived.isEmpty else { return }
                if AppSettings.shared.taildropToShelf { ShelfStore.shared.add(arrived) }
                let what = arrived.count == 1 ? arrived[0].lastPathComponent : "\(arrived.count) files"
                ActivityCenter.shared.show(.taildrop(title: "Received via Taildrop", detail: what, received: true), for: 4)
            }
        }
    }

    // MARK: - CLI

    nonisolated private static func run(_ cli: String, _ args: [String],
                                        onOutput: (@Sendable (String) -> Void)? = nil) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            buffer.append(text)
            onOutput?(text)
        }
        do { try p.run() } catch { return (-1, "") }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) { buffer.append(rest) }
        return (p.terminationStatus, buffer.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated private static func lastPercent(in text: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)%"#) else { return nil }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last, let r = Range(last.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = ""
        func append(_ s: String) { lock.lock(); storage += s; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
