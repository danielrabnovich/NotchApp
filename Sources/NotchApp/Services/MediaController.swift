import AppKit
import SwiftUI

/// Now-playing state for any app (Music, Spotify, browsers, Podcasts…).
///
/// Since macOS 15.4 the private MediaRemote framework only answers entitled
/// processes, so we load a tiny bridge (MediaAdapter.dylib) into /usr/bin/perl,
/// which still is, and stream JSON lines from it.
@MainActor
final class MediaController: ObservableObject {
    static let shared = MediaController()

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accentColor: NSColor = .white
    @Published private(set) var bundleID: String?
    @Published private(set) var appName: String?

    /// Elapsed time is extrapolated from this anchor while playing.
    @Published private(set) var elapsedAnchor: Double = 0
    private var anchorDate = Date()
    private var rate: Double = 1

    private var process: Process?
    private var buffer = Data()
    private var stopped = false

    var hasTrack: Bool { !title.isEmpty }

    func elapsed(at date: Date = Date()) -> Double {
        guard isPlaying else { return elapsedAnchor }
        let value = elapsedAnchor + date.timeIntervalSince(anchorDate) * rate
        return duration > 0 ? min(max(0, value), duration) : max(0, value)
    }

    var appIcon: NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Process

    private var adapterPaths: (script: String, lib: String)? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let script = res.appendingPathComponent("adapter.pl").path
        let lib = res.appendingPathComponent("MediaAdapter.dylib").path
        guard FileManager.default.fileExists(atPath: script), FileManager.default.fileExists(atPath: lib) else { return nil }
        return (script, lib)
    }

    func start() {
        stopped = false
        guard process == nil, let paths = adapterPaths else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script, paths.lib, "stream"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                if !self.stopped {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() }
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("NotchApp: failed to start media adapter: \(error)")
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                apply(obj)
            }
        }
    }

    private func apply(_ info: [String: Any]) {
        let newTitle = info["title"] as? String ?? ""
        let playing = (info["playing"] as? NSNumber)?.boolValue ?? false

        if newTitle.isEmpty {
            title = ""; artist = ""; album = ""; duration = 0
            isPlaying = false; artwork = nil; accentColor = .white
            bundleID = nil; appName = nil; elapsedAnchor = 0
            return
        }

        title = newTitle
        artist = info["artist"] as? String ?? ""
        album = info["album"] as? String ?? ""
        duration = (info["duration"] as? NSNumber)?.doubleValue ?? 0
        bundleID = info["bundle"] as? String
        appName = info["app"] as? String

        let r = (info["rate"] as? NSNumber)?.doubleValue ?? (playing ? 1 : 0)
        rate = r > 0 ? r : 1
        elapsedAnchor = (info["elapsed"] as? NSNumber)?.doubleValue ?? 0
        if let ts = (info["timestamp"] as? NSNumber)?.doubleValue {
            anchorDate = Date(timeIntervalSince1970: ts)
        } else {
            anchorDate = Date()
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isPlaying = playing }

        if let b64 = info["artwork"] as? String, let data = Data(base64Encoded: b64), let image = NSImage(data: data) {
            artwork = image
            accentColor = image.vibrantAverageColor ?? .white
        } else if info["artworkId"] == nil {
            artwork = nil
            accentColor = .white
        }
    }

    // MARK: - Commands (MRCommand values)

    func togglePlayPause() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if isPlaying { elapsedAnchor = elapsed() } else { anchorDate = Date() }
            isPlaying.toggle()
        }
        send(env: ["NOTCH_MR_CMD": "2"])
    }

    /// Debug only: pretend the current track is playing without touching the player.
    func debugSetPlaying(_ playing: Bool) {
        anchorDate = Date()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isPlaying = playing }
    }

    func nextTrack() { send(env: ["NOTCH_MR_CMD": "4"]) }
    func previousTrack() { send(env: ["NOTCH_MR_CMD": "5"]) }

    func seek(to seconds: Double) {
        elapsedAnchor = seconds
        anchorDate = Date()
        send(env: ["NOTCH_MR_SEEK": String(seconds)])
    }

    func openSourceApp() {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func send(env: [String: String]) {
        guard let paths = adapterPaths else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script, paths.lib, "send"]
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

extension NSImage {
    /// Average colour of the image, nudged to stay bright and readable on black.
    var vibrantAverageColor: NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = 12
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        // Weight saturated pixels more so we pick the "interesting" colour, not the muddy average.
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in 0..<(size * size) {
            let pr = Double(px[i * 4]) / 255, pg = Double(px[i * 4 + 1]) / 255, pb = Double(px[i * 4 + 2]) / 255
            let maxC = max(pr, pg, pb), minC = min(pr, pg, pb)
            let w = 0.15 + (maxC - minC) * 2 + maxC * 0.3
            r += pr * w; g += pg * w; b += pb * w; total += w
        }
        guard total > 0 else { return nil }
        let c = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        if s < 0.12 { return NSColor(white: 0.92, alpha: 1) }
        return NSColor(hue: h, saturation: min(1, max(s, 0.45)), brightness: max(v, 0.85), alpha: 1)
    }
}
