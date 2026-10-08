import AppKit
import SwiftUI

/// Video and audio downloads with yt-dlp, using the copy Homebrew installed (nothing is bundled).
/// Files land in Downloads, with progress beside the notch and the finished file on the shelf.
@MainActor
final class VideoDownloader: ObservableObject {
    static let shared = VideoDownloader()

    enum Format: String, Equatable {
        case video, audio
        var label: String { self == .video ? "Video" : "Audio" }
    }

    struct Job: Identifiable, Equatable {
        enum State: Equatable {
            case starting
            case downloading
            /// Merging streams or converting audio with ffmpeg.
            case processing
            case done(URL)
            case failed(String)
        }

        let id = UUID()
        let url: URL
        let format: Format
        /// Maximum height ("1080"), or nil for the best available.
        var height: Int?
        var title: String?
        var state: State = .starting
        var downloaded: Int64 = 0
        var total: Int64 = 0
        var speed: Double = 0 // bytes per second
        var eta: Int?

        var progress: Double { total > 0 ? min(1, Double(downloaded) / Double(total)) : 0 }
        var isActive: Bool { [.starting, .downloading, .processing].contains(state) }
        var displayTitle: String { title ?? url.host() ?? url.absoluteString }
    }

    @Published private(set) var jobs: [Job] = []
    private var processes: [UUID: Process] = [:]

    private init() {}

    /// yt-dlp from Homebrew (Apple silicon or Intel prefix), if it's installed.
    nonisolated static var binary: URL? {
        ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { binary != nil }

    var active: [Job] { jobs.filter(\.isActive) }
    /// The download beside the notch: the one furthest from done.
    var current: Job? { active.min { $0.progress < $1.progress } }

    /// A web address worth handing to yt-dlp (http/https with a host).
    nonisolated static func webURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), !t.contains("\n"), let url = URL(string: t),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
        return url
    }

    // MARK: - Run

    /// Downloads at the default quality from Settings.
    func download(_ url: URL, format: Format) {
        let preferred = AppSettings.shared.videoQuality
        download(url, format: format, height: format == .video && preferred > 0 ? preferred : nil)
    }

    func download(_ url: URL, format: Format, height: Int?) {
        guard let binary = Self.binary else {
            ActivityCenter.shared.show(.notice(title: "yt-dlp isn't installed", detail: "brew install yt-dlp", icon: "arrow.down.circle", tone: .warning), for: 4)
            return
        }
        if jobs.contains(where: { $0.url == url && $0.format == format && $0.isActive }) { return }
        var job = Job(url: url, format: format, height: height)
        job.state = .starting
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { jobs.insert(job, at: 0) }
        let id = job.id

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var args = ["--newline", "--no-playlist", "--no-simulate", "--progress", "--no-mtime",
                    "--progress-template", "download:NOTCH %(progress.downloaded_bytes)s %(progress.total_bytes,progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s",
                    "--print", "before_dl:TITLE %(title)s",
                    "--print", "after_move:FILE %(filepath)s",
                    "-o", downloads.path + "/%(title).120B [%(id)s].%(ext)s"]
        if let ffmpeg = Self.ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        switch format {
        case .video:
            if let height {
                // That height in the most compatible codec: H.264 (plays everywhere), then AV1 (QuickTime on
                // M3 and later), then whatever the site has. If it isn't offered, the largest size below it.
                let h = "[height=\(height)]"
                args += ["-f", "bv*\(h)[vcodec^=avc]+ba[ext=m4a]/bv*\(h)[vcodec^=av01]+ba/bv*\(h)+ba/bv*+ba/b",
                         "-S", "res:\(height),ext:mp4:m4a", "--merge-output-format", "mp4"]
            } else {
                // Best available, preferring streams that are already MP4.
                args += ["-f", "bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b", "--merge-output-format", "mp4"]
            }
        case .audio:
            args += ["-x", "--audio-format", "m4a"]
        }
        args.append(url.absoluteString)

        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let lastError = ErrorLine()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let line = String(line)
                Task { @MainActor in VideoDownloader.shared.handle(line, for: id) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            // Keep the last error line yt-dlp printed, for the failure message.
            if let line = text.split(whereSeparator: \.isNewline).last(where: { $0.contains("ERROR") }) {
                lastError.set(String(line))
            }
            if text.contains("[Merger]") || text.contains("[ExtractAudio]") || text.contains("[VideoConvertor]") {
                Task { @MainActor in VideoDownloader.shared.update(id) { $0.state = .processing } }
            }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            let killed = proc.terminationReason == .uncaughtSignal
            let message = lastError.text
            Task { @MainActor in VideoDownloader.shared.finished(id, status: status, cancelled: killed, error: message) }
        }
        do {
            try p.run()
            processes[id] = p
        } catch {
            update(id) { $0.state = .failed("Couldn't start yt-dlp") }
        }
    }

    func cancel(_ job: Job) {
        processes[job.id]?.terminate()
    }

    func dismiss(_ job: Job) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { jobs.removeAll { $0.id == job.id } }
    }

    func clearFinished() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { jobs.removeAll { !$0.isActive } }
    }

    private func handle(_ line: String, for id: UUID) {
        if line.hasPrefix("TITLE ") {
            update(id) { $0.title = String(line.dropFirst(6)) }
        } else if line.hasPrefix("FILE ") {
            let url = URL(fileURLWithPath: String(line.dropFirst(5)))
            update(id) { $0.state = .done(url) }
        } else if line.hasPrefix("NOTCH ") {
            let parts = line.split(separator: " ").dropFirst().map(String.init)
            guard parts.count >= 4 else { return }
            update(id) { job in
                if job.state == .starting || job.state == .downloading { job.state = .downloading }
                let done = Int64(Double(parts[0]) ?? 0), total = Int64(Double(parts[1]) ?? 0)
                // Video and audio download one after the other; keep the bar moving forward.
                if total > 0 && total != job.total && done < job.downloaded { job.downloaded = 0 }
                job.downloaded = done
                job.total = total
                job.speed = Double(parts[2]) ?? job.speed
                job.eta = Int(parts[3])
            }
        }
    }

    private func finished(_ id: UUID, status: Int32, cancelled: Bool, error: String) {
        processes[id] = nil
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if cancelled {
            dismiss(job)
            return
        }
        if case .done(let file) = job.state, status == 0 {
            ActivityCenter.shared.show(.download(name: file.lastPathComponent), for: 4)
            if AppSettings.shared.shelfEnabled, AppSettings.shared.videoDownloadsToShelf { ShelfStore.shared.add([file]) }
            return
        }
        let reason = error
            .replacingOccurrences(of: "ERROR: ", with: "")
            .replacingOccurrences(of: #"^\[[^\]]+\] [^:]+: "#, with: "", options: .regularExpression)
        update(id) { $0.state = .failed(reason.isEmpty ? "Download failed" : String(reason.prefix(120))) }
        ActivityCenter.shared.show(.notice(title: "Download failed", detail: job.displayTitle, icon: "arrow.down.circle", tone: .warning), for: 4)
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[i]
        change(&job)
        if job != jobs[i] { jobs[i] = job }
    }

    // MARK: - Qualities

    struct Quality: Identifiable, Equatable {
        var id: Int { height }
        let height: Int
        /// "H.264", "VP9", "AV1".
        let codec: String
        /// Estimated size with audio, when the site says.
        let size: Int64?

        var label: String {
            switch height {
            case 4320...: "8K"
            case 2160...: "4K"
            default: "\(height)p"
            }
        }

        /// Everything plays H.264; AV1 needs an M3 or later for QuickTime, VP9 needs IINA or VLC.
        var detail: String {
            [codec, size.map { "~" + formatBytes($0) }].compactMap { $0 }.joined(separator: " · ")
        }
    }

    struct MediaInfo: Equatable {
        let title: String?
        let qualities: [Quality]
        let audioSize: Int64?
    }

    private var probes: [URL: MediaInfo] = [:]
    private var probing: Set<URL> = []

    /// What's on offer at a link (cached), or nil while it's being checked.
    func cachedInfo(for url: URL) -> MediaInfo? { probes[url] }
    func isProbing(_ url: URL) -> Bool { probing.contains(url) }

    /// Asks yt-dlp which resolutions a link has (a couple of seconds; nothing is downloaded).
    func probe(_ url: URL) async -> MediaInfo? {
        if let cached = probes[url] { return cached }
        guard let binary = Self.binary else { return nil }
        probing.insert(url)
        defer { probing.remove(url) }
        let result = await Shell.run(binary.path, ["-J", "--no-playlist", "--no-warnings", url.absoluteString], timeout: 30)
        guard result.ok, let data = result.out.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let info = Self.parse(obj)
        probes[url] = info
        return info
    }

    nonisolated private static func parse(_ obj: [String: Any]) -> MediaInfo {
        let formats = obj["formats"] as? [[String: Any]] ?? []
        func size(_ f: [String: Any]) -> Int64? {
            ((f["filesize"] as? NSNumber) ?? (f["filesize_approx"] as? NSNumber)).map { $0.int64Value }
        }
        let audio = formats.filter { ($0["vcodec"] as? String) == "none" && ($0["acodec"] as? String ?? "none") != "none" }
        let audioSize = audio.compactMap(size).max()
        var byHeight: [Int: [[String: Any]]] = [:]
        for f in formats {
            guard let vcodec = f["vcodec"] as? String, vcodec != "none", let h = (f["height"] as? NSNumber)?.intValue, h >= 144 else { continue }
            byHeight[h, default: []].append(f)
        }
        let qualities: [Quality] = byHeight.keys.sorted(by: >).compactMap { h in
            let options = byHeight[h] ?? []
            // What the download will pick at this height: H.264, then AV1, then the richest other stream.
            func codec(_ prefix: String) -> [[String: Any]] { options.filter { ($0["vcodec"] as? String ?? "").hasPrefix(prefix) } }
            let family = [codec("avc"), codec("av01")].first { !$0.isEmpty } ?? options
            // Within the codec, one that states its size if possible (streamed variants often don't).
            let pick = family.filter { size($0) != nil }.max { (size($0) ?? 0) < (size($1) ?? 0) }
                ?? family.max { (($0["tbr"] as? NSNumber)?.doubleValue ?? 0) < (($1["tbr"] as? NSNumber)?.doubleValue ?? 0) }
            guard let pick else { return nil }
            let vcodec = (pick["vcodec"] as? String ?? "").lowercased()
            let codec = vcodec.hasPrefix("avc") ? "H.264" : vcodec.hasPrefix("av01") ? "AV1"
                : vcodec.hasPrefix("vp9") || vcodec.hasPrefix("vp09") ? "VP9" : vcodec.hasPrefix("hev") || vcodec.hasPrefix("hvc") ? "HEVC"
                : vcodec.uppercased()
            let videoSize = size(pick)
            let separateAudio = (pick["acodec"] as? String ?? "none") == "none"
            return Quality(height: h, codec: codec, size: videoSize.map { $0 + (separateAudio ? (audioSize ?? 0) : 0) })
        }
        return MediaInfo(title: obj["title"] as? String, qualities: qualities, audioSize: audioSize)
    }

    /// A menu at the pointer: each resolution the link offers, plus audio only.
    func chooseQuality(for url: URL) {
        Task {
            if probes[url] == nil {
                ActivityCenter.shared.show(.notice(title: "Checking qualities…", detail: url.host() ?? "yt-dlp", icon: "arrow.down.circle", tone: .info), for: 2)
            }
            guard let info = await probe(url), !info.qualities.isEmpty else {
                download(url, format: .video) // the site didn't list resolutions; take what it has
                return
            }
            var items: [(String, () -> Void)] = info.qualities.map { q in
                ("\(q.label)  ·  \(q.detail)", { VideoDownloader.shared.download(url, format: .video, height: q.height) })
            }
            items.append(("Audio only (M4A)" + (info.audioSize.map { "  ·  ~" + formatBytes($0) } ?? ""),
                          { VideoDownloader.shared.download(url, format: .audio, height: nil) }))
            PopUpMenu.show(items, title: info.title.map { String($0.prefix(60)) } ?? "Download")
        }
    }

    /// Updates yt-dlp through Homebrew (sites change often; an old copy is the usual cause of failures).
    func upgrade() {
        Task {
            ActivityCenter.shared.show(.notice(title: "Updating yt-dlp…", detail: "Homebrew", icon: "arrow.triangle.2.circlepath", tone: .info), for: 3)
            let brew = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
            let result = await Shell.run(brew, ["upgrade", "yt-dlp"], timeout: 300)
            ActivityCenter.shared.show(.notice(title: result.ok ? "yt-dlp is up to date" : "Couldn't update yt-dlp",
                                               detail: "Homebrew", icon: result.ok ? "checkmark.circle" : "xmark.circle", tone: result.ok ? .success : .warning), for: 3)
        }
    }
}

/// The last error line yt-dlp printed (written from the pipe's queue, read when it exits).
private final class ErrorLine: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var text: String { lock.withLock { value } }
    func set(_ line: String) { lock.withLock { value = line } }
}
