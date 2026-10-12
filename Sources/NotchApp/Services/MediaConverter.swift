import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Quick conversions for files on the shelf or dropped on the notch: shrink a video, make a GIF,
/// pull out the audio, turn HEIC into JPEG. Video and audio use Homebrew's ffmpeg; images use
/// macOS's own `sips`. The result is saved next to the original and put on the shelf.
@MainActor
final class MediaConverter: ObservableObject {
    static let shared = MediaConverter()

    enum Operation: String, CaseIterable, Identifiable {
        case compressVideo, toMP4, toWebM, toGIF, makeVertical, audioM4A, audioMP3, audioWAV
        case toMP3, toM4A, toWAV, toFLAC, toAIFF, normalizeLoudness
        case toJPEG, toPNG, toHEIC, toWebP, toTIFF, halfSize, youtubeThumbnail

        var id: String { rawValue }

        var title: String {
            switch self {
            case .compressVideo: "Compress Video"
            case .toMP4: "Convert to MP4"
            case .toWebM: "Convert to WebM"
            case .toGIF: "Make a GIF"
            case .makeVertical: "Make Vertical (9:16)"
            case .audioM4A: "Extract Audio (M4A)"
            case .audioMP3: "Extract Audio (MP3)"
            case .audioWAV: "Extract Audio (WAV)"
            case .toMP3: "Convert to MP3"
            case .toM4A: "Convert to M4A"
            case .toWAV: "Convert to WAV"
            case .toFLAC: "Convert to FLAC"
            case .toAIFF: "Convert to AIFF"
            case .normalizeLoudness: "Normalize Loudness"
            case .toJPEG: "Convert to JPEG"
            case .toPNG: "Convert to PNG"
            case .toHEIC: "Convert to HEIC"
            case .toWebP: "Convert to WebP"
            case .toTIFF: "Convert to TIFF"
            case .halfSize: "Resize to Half"
            case .youtubeThumbnail: "YouTube Thumbnail (1280×720)"
            }
        }

        var suffix: String {
            switch self {
            case .compressVideo: " (compressed)"
            case .halfSize: " (half size)"
            case .makeVertical: " (vertical)"
            case .normalizeLoudness: " (normalized)"
            case .youtubeThumbnail: " (thumbnail)"
            default: ""
            }
        }

        var outputExtension: String? {
            switch self {
            case .compressVideo, .toMP4, .makeVertical: "mp4"
            case .toWebM: "webm"
            case .toGIF: "gif"
            case .audioM4A, .toM4A: "m4a"
            case .audioMP3, .toMP3: "mp3"
            case .audioWAV, .toWAV: "wav"
            case .toFLAC: "flac"
            case .toAIFF: "aiff"
            case .toJPEG, .youtubeThumbnail: "jpg"
            case .toPNG: "png"
            case .toHEIC: "heic"
            case .toWebP: "webp"
            case .toTIFF: "tiff"
            case .halfSize, .normalizeLoudness: nil // keeps its type
            }
        }

        /// A change of format, pointless on a file already in it.
        var isFormatChange: Bool { ![.compressVideo, .halfSize, .normalizeLoudness, .makeVertical, .youtubeThumbnail, .toGIF].contains(self) }

        var usesFFmpeg: Bool { ![.toJPEG, .toPNG, .toHEIC, .toTIFF, .halfSize, .toWebP].contains(self) }
    }

    enum Kind { case video, audio, image }

    struct Job: Identifiable, Equatable {
        enum State: Equatable { case running, done(URL), failed(String) }
        let id = UUID()
        let source: URL
        let operation: Operation
        var state: State = .running
        var progress: Double?
        var isActive: Bool { state == .running }
    }

    @Published private(set) var jobs: [Job] = []
    private var processes: [UUID: Process] = [:]

    private init() {}

    nonisolated static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image), !type.conforms(to: .pdf) { return .image }
        return nil
    }

    /// What can be done with a set of files (they must all be the same kind), most useful first;
    /// never a format they're all already in.
    static func operations(for urls: [URL]) -> [Operation] {
        let kinds = Set(urls.compactMap(kind(of:)))
        guard kinds.count == 1, let kind = kinds.first, urls.allSatisfy({ Self.kind(of: $0) != nil }) else { return [] }
        let ffmpeg = VideoDownloader.ffmpeg != nil
        let exts = Set(urls.map { $0.pathExtension.lowercased() }.map { $0 == "jpeg" ? "jpg" : $0 == "aif" ? "aiff" : $0 == "tif" ? "tiff" : $0 })
        let all: [Operation]
        switch kind {
        case .video: all = [.compressVideo, .toGIF, .makeVertical, .toMP4, .toWebM, .audioM4A, .audioMP3, .audioWAV]
        case .audio: all = [.toMP3, .toM4A, .normalizeLoudness, .toWAV, .toFLAC, .toAIFF]
        case .image: all = [.toJPEG, .toPNG, .toHEIC, .toWebP, .toTIFF, .halfSize, .youtubeThumbnail]
        }
        return all.filter { op in
            // WebP comes from Homebrew's cwebp (macOS can't write it), which reads PNG, JPEG and TIFF.
            if op == .toWebP { return cwebp != nil && exts.isSubset(of: ["png", "jpg", "tiff"]) }
            return (ffmpeg || !op.usesFFmpeg) && !(op.isFormatChange && exts == [op.outputExtension ?? ""])
        }
    }

    nonisolated static let cwebp: String? = ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// A menu at the pointer with what these files can become.
    func offer(_ urls: [URL]) {
        let ops = Self.operations(for: urls)
        guard !ops.isEmpty else {
            let anyMedia = urls.contains { Self.kind(of: $0) != nil }
            ActivityCenter.shared.show(.notice(title: anyMedia && VideoDownloader.ffmpeg == nil ? "Install ffmpeg to convert video" : "Nothing to convert",
                                               detail: anyMedia ? "brew install ffmpeg" : "Videos, audio and images", icon: "wand.and.stars", tone: .warning), for: 3)
            return
        }
        PopUpMenu.show(ops.map { op in (op.title, { MediaConverter.shared.convert(urls, op) }) },
                       title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
    }

    func convert(_ urls: [URL], _ operation: Operation) {
        for url in urls { start(url, operation) }
    }

    func cancel(_ job: Job) { processes[job.id]?.terminate() }

    func dismiss(_ job: Job) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { jobs.removeAll { $0.id == job.id } }
    }

    // MARK: - Run

    private func start(_ source: URL, _ op: Operation) {
        let output = Self.outputURL(for: source, op)
        var job = Job(source: source, operation: op)
        job.progress = op.usesFFmpeg ? 0 : nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { jobs.insert(job, at: 0) }
        let id = job.id

        let p = Process()
        if op.usesFFmpeg {
            guard let ffmpeg = VideoDownloader.ffmpeg else { return }
            p.executableURL = ffmpeg
            p.arguments = ["-hide_banner", "-nostdin", "-y", "-i", source.path] + Self.ffmpegArgs(op, source: source) + ["-progress", "pipe:1", "-nostats", output.path]
        } else if op == .toWebP, let cwebp = Self.cwebp {
            p.executableURL = URL(fileURLWithPath: cwebp)
            p.arguments = ["-quiet", "-q", "85", source.path, "-o", output.path]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            p.arguments = Self.sipsArgs(op, source: source) + [source.path, "--out", output.path]
        }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if op.usesFFmpeg {
            // Progress needs the length; ask ffprobe (next to ffmpeg) once.
            let probe = VideoDownloader.ffmpeg?.deletingLastPathComponent().appendingPathComponent("ffprobe").path
            Task.detached {
                guard let probe else { return }
                let result = Shell.runSync(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", source.path], timeout: 10)
                let seconds = Double(result.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                await MainActor.run { MediaConverter.shared.durations[id] = seconds }
            }
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                // "out_time_us=12345678"
                guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("out_time_us=") }),
                      let us = Double(line.dropFirst("out_time_us=".count)) else { return }
                Task { @MainActor in MediaConverter.shared.progress(id, seconds: us / 1_000_000) }
            }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            let ok = proc.terminationStatus == 0
            let cancelled = proc.terminationReason == .uncaughtSignal
            Task { @MainActor in MediaConverter.shared.finished(id, output: output, ok: ok, cancelled: cancelled) }
        }
        do {
            try p.run()
            processes[id] = p
        } catch {
            update(id) { $0.state = .failed("Couldn't start") }
        }
    }

    private var durations: [UUID: Double] = [:]

    private func progress(_ id: UUID, seconds: Double) {
        guard let total = durations[id], total > 0 else { return }
        update(id) { $0.progress = min(1, seconds / total) }
    }

    private func finished(_ id: UUID, output: URL, ok: Bool, cancelled: Bool) {
        processes[id] = nil
        durations[id] = nil
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if cancelled {
            try? FileManager.default.removeItem(at: output)
            dismiss(job)
            return
        }
        guard ok, FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            update(id) { $0.state = .failed("\(job.operation.title) failed") }
            ActivityCenter.shared.show(.notice(title: "Conversion failed", detail: job.source.lastPathComponent, icon: "wand.and.stars", tone: .warning), for: 4)
            return
        }
        update(id) { $0.state = .done(output); $0.progress = 1 }
        let before = Cleaner.allocatedSize(job.source), after = Cleaner.allocatedSize(output)
        let sizes = before > 0 && after > 0 ? "\(formatBytes(before)) → \(formatBytes(after))" : output.lastPathComponent
        ActivityCenter.shared.show(.notice(title: job.operation.title.replacingOccurrences(of: "Convert to ", with: "Now "),
                                           detail: sizes, icon: "wand.and.stars"), for: 4)
        if AppSettings.shared.shelfEnabled, AppSettings.shared.convertToShelf { ShelfStore.shared.add([output]) }
        // Finished conversions clear themselves after a while; the file is on the shelf.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if let job = self?.jobs.first(where: { $0.id == id }), !job.isActive { self?.dismiss(job) }
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[i]
        change(&job)
        if job != jobs[i] { jobs[i] = job }
    }

    // MARK: - Commands

    nonisolated private static func ffmpegArgs(_ op: Operation, source: URL) -> [String] {
        let h264 = ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        switch op {
        case .compressVideo:
            // About a third of the size of a phone or screen recording, still sharp.
            return ["-c:v", "libx264", "-crf", "26", "-preset", "medium", "-pix_fmt", "yuv420p",
                    "-vf", "scale='min(1920,iw)':-2", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
        case .toMP4:
            return h264
        case .makeVertical:
            // The middle of the frame at 9:16, 1080×1920, for Reels, TikTok and Shorts.
            return ["-vf", "crop='min(iw,ih*9/16)':ih,scale=1080:1920:flags=lanczos,setsar=1"] + h264
        case .toWebM:
            return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case .toGIF:
            return ["-vf", "fps=12,scale='min(640,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                    "-loop", "0"]
        case .audioM4A, .toM4A: return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case .audioMP3, .toMP3: return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .audioWAV, .toWAV: return ["-vn", "-c:a", "pcm_s16le"]
        case .toFLAC: return ["-vn", "-c:a", "flac"]
        case .toAIFF: return ["-vn", "-c:a", "pcm_s16be"]
        case .normalizeLoudness:
            // −14 LUFS, what YouTube, Spotify and most podcast apps play at; kept in its own format.
            let codec: [String] = switch source.pathExtension.lowercased() {
            case "mp3": ["-c:a", "libmp3lame", "-q:a", "2"]
            case "m4a", "aac": ["-c:a", "aac", "-b:a", "256k"]
            case "flac": ["-c:a", "flac"]
            case "aif", "aiff": ["-c:a", "pcm_s16be"]
            default: ["-c:a", "pcm_s16le"]
            }
            return ["-vn", "-af", "loudnorm=I=-14:TP=-1:LRA=11"] + codec
        case .toWebP: return ["-c:v", "libwebp", "-quality", "85", "-frames:v", "1"]
        case .youtubeThumbnail:
            // Filled to 16:9 and cropped, well under YouTube's 2 MB.
            return ["-vf", "scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720", "-q:v", "3", "-frames:v", "1"]
        case .toJPEG, .toPNG, .toHEIC, .toTIFF, .halfSize: return []
        }
    }

    nonisolated private static func sipsArgs(_ op: Operation, source: URL) -> [String] {
        switch op {
        case .toJPEG: return ["-s", "format", "jpeg", "-s", "formatOptions", "85"]
        case .toPNG: return ["-s", "format", "png"]
        case .toHEIC: return ["-s", "format", "heic", "-s", "formatOptions", "80"]
        case .toTIFF: return ["-s", "format", "tiff"]
        case .halfSize:
            let width = NSImageRep(contentsOf: source)?.pixelsWide ?? 0
            return width > 1 ? ["--resampleWidth", String(width / 2)] : ["-Z", "1024"]
        default: return []
        }
    }

    /// "Clip.mov" → "Clip (compressed).mp4", numbered if that name is taken.
    nonisolated private static func outputURL(for source: URL, _ op: Operation) -> URL {
        let folder = source.deletingLastPathComponent()
        let writable = FileManager.default.isWritableFile(atPath: folder.path)
        let dir = writable ? folder : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = source.deletingPathExtension().lastPathComponent + op.suffix
        let ext = op.outputExtension ?? source.pathExtension
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || url == source {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}
