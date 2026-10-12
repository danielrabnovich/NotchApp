import AppKit
import Vision

/// QR codes on screen: every display is looked at once (as a screenshot, never saved), and the
/// codes found are offered to open or copy. A link is never opened without asking: QR codes are
/// a favourite way to hide a bad one.
@MainActor
enum QRScanner {
    static func scan() {
        Task {
            let codes = await Self.findCodes()
            guard let first = codes.first else {
                ActivityCenter.shared.show(.notice(title: "No QR code on screen", detail: "Make it bigger, or bring its window to the front",
                                                   icon: "qrcode.viewfinder", tone: .info), for: 3)
                return
            }
            let url = URL(string: first).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            let shown = url.map { LinkCleaner.clean($0.absoluteString)?.link ?? $0.absoluteString } ?? first
            var actions: [Prompt.Action] = []
            if url != nil, let link = URL(string: shown) {
                actions.append(.init(title: "Open", primary: true) { NSWorkspace.shared.open(link) })
            }
            actions.append(.init(title: "Copy", primary: url == nil) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shown, forType: .string)
            })
            let title = url?.host().map { "QR code: \($0.replacingOccurrences(of: "www.", with: ""))" } ?? "QR code"
            let more = codes.count > 1 ? " · \(codes.count - 1) more on screen" : ""
            NotchPresenter.shared.offer(Prompt(icon: "qrcode", tint: .systemBlue, title: title,
                                               detail: String(shown.prefix(90)) + more, actions: actions), peek: true)
        }
    }

    /// The payloads of the QR codes on every display, biggest first.
    private nonisolated static func findCodes() async -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NotchApp-QR-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = (0..<max(1, NSScreen.screens.count)).map { dir.appendingPathComponent("\($0).png").path }
        _ = await Shell.run("/usr/sbin/screencapture", ["-x"] + files, timeout: 10)
        var found: [(String, CGFloat)] = []
        for path in files {
            guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr, .microQR, .aztec, .dataMatrix]
            try? VNImageRequestHandler(cgImage: image).perform([request])
            for result in request.results ?? [] {
                if let payload = result.payloadStringValue, !payload.isEmpty {
                    found.append((payload, result.boundingBox.width * result.boundingBox.height))
                }
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0).inserted }
    }
}

/// A Banner when macOS starts slowing the Mac down to cool it, naming what's working it hardest.
@MainActor
final class HeatWatcher {
    static let shared = HeatWatcher()
    private var lastAlert = Date.distantPast

    func start() {
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HeatWatcher.shared.check() }
        }
    }

    private func check() {
        let state = ProcessInfo.processInfo.thermalState
        // "Serious" is when macOS starts holding the processor back; once in 20 minutes is plenty.
        guard state == .serious || state == .critical, Date().timeIntervalSince(lastAlert) > 20 * 60 else { return }
        lastAlert = Date()
        Task {
            let busiest = await Self.busiestApp()
            ActivityCenter.shared.show(.notice(title: state == .critical ? "Your Mac is very hot" : "Your Mac is running hot",
                                               detail: "macOS is slowing it down to cool off" + (busiest.map { " · \($0) is working hardest" } ?? ""),
                                               icon: "thermometer.high", tone: .warning), for: 6)
        }
    }

    /// The app using the most processor right now, by name.
    private nonisolated static func busiestApp() async -> String? {
        let out = await Shell.run("/bin/ps", ["-Arco", "pcpu=,comm="], timeout: 3).out
        guard let line = out.split(separator: "\n").first else { return nil }
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, (Double(parts[0]) ?? 0) > 20 else { return nil }
        return String(parts[1])
    }
}
