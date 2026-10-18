import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Quick conversions for files on the shelf or dropped on the notch: shrink a video, make a GIF,
/// pull out the audio, turn HEIC into JPEG. Video and audio use Homebrew's ffmpeg; images use
/// macOS's own `sips`. The result is saved next to the original and put on the shelf.
@MainActor
final class MediaConverter: ObservableObject {
    static let shared = MediaConverter()

    enum Operation: String, CaseIterable, Identifiable {
        case compressVideo, toMP4, toMP4HEVC, toMP4AV1, toWebM, toWebMAV1, toProRes, toMKV, toGIF, makeVertical, audioM4A, audioMP3, audioWAV
        case to1080p, to720p, muteVideo, speedUp
        case toMP3, toM4A, toWAV, toFLAC, toAIFF, normalizeLoudness, trimSilence
        case toJPEG, toPNG, toHEIC, toWebP, toTIFF, halfSize, quarterSize, forWeb, youtubeThumbnail

        var id: String { rawValue }

        var title: String {
            switch self {
            case .compressVideo: "Compress Video"
            case .toMP4: "Convert to MP4 (H.264)"
            case .toMP4HEVC: "Convert to MP4 (HEVC)"
            case .toMP4AV1: "Convert to MP4 (AV1)"
            case .toWebM: "Convert to WebM (VP9)"
            case .toProRes: "Convert to ProRes (MOV)"
            case .toMKV: "Convert to MKV"
            case .toWebMAV1: "Convert to WebM (AV1)"
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
            case .quarterSize: "Resize to Quarter"
            case .forWeb: "Optimize for Web"
            case .youtubeThumbnail: "YouTube Thumbnail (1280×720)"
            case .to1080p: "Resize to 1080p"
            case .to720p: "Resize to 720p"
            case .muteVideo: "Remove Audio"
            case .speedUp: "Speed Up 2×"
            case .trimSilence: "Trim Silence"
            }
        }

        /// Short names for chips and drop targets ("GIF" rather than "Make a GIF").
        var shortTitle: String {
            switch self {
            case .compressVideo: "Compress"
            case .toGIF: "GIF"
            case .toMP4: "MP4 · H.264"
            case .toMP4HEVC: "MP4 · HEVC"
            case .toMP4AV1: "MP4 · AV1"
            case .toWebM: "WebM · VP9"
            case .toWebMAV1: "WebM · AV1"
            case .toProRes: "ProRes"
            case .makeVertical: "Vertical"
            case .audioM4A, .audioMP3, .audioWAV: "Audio · \(outputExtension?.uppercased() ?? "")"
            case .normalizeLoudness: "Normalize"
            case .halfSize: "Half Size"
            case .quarterSize: "Quarter"
            case .forWeb: "For Web"
            case .youtubeThumbnail: "Thumbnail"
            case .to1080p: "1080p"
            case .to720p: "720p"
            case .muteVideo: "No Audio"
            case .speedUp: "2× Speed"
            case .trimSilence: "Trim Silence"
            default: outputExtension?.uppercased() ?? title
            }
        }

        var symbol: String {
            switch self {
            case .toGIF: "photo.stack"
            case .compressVideo: "arrow.down.right.and.arrow.up.left"
            case .makeVertical: "rectangle.portrait"
            case .normalizeLoudness: "speaker.wave.2"
            case .audioM4A, .audioMP3, .audioWAV, .toMP3, .toM4A, .toWAV, .toFLAC, .toAIFF: "waveform"
            case .halfSize, .quarterSize, .to1080p, .to720p: "arrow.down.left.and.arrow.up.right"
            case .forWeb: "globe"
            case .youtubeThumbnail: "play.rectangle"
            case .toMP4, .toMP4HEVC, .toMP4AV1, .toWebM, .toWebMAV1, .toProRes, .toMKV: "film"
            case .muteVideo: "speaker.slash"
            case .speedUp: "hare"
            case .trimSilence: "scissors"
            default: "photo"
            }
        }

        /// Menus list new formats first, then changes that keep the format.
        var isEdit: Bool { outputExtension == nil || [.compressVideo, .makeVertical, .to1080p, .to720p, .muteVideo, .speedUp, .toGIF, .youtubeThumbnail, .forWeb].contains(self) }

        var suffix: String {
            switch self {
            case .compressVideo: " (compressed)"
            case .halfSize: " (half size)"
            case .makeVertical: " (vertical)"
            case .normalizeLoudness: " (normalized)"
            case .youtubeThumbnail: " (thumbnail)"
            case .quarterSize: " (quarter size)"
            case .forWeb: " (web)"
            case .to1080p: " (1080p)"
            case .to720p: " (720p)"
            case .muteVideo: " (no audio)"
            case .speedUp: " (2x)"
            case .trimSilence: " (trimmed)"
            // Codec choices that can land in the source's own container say which they are.
            case .toMP4HEVC: " (HEVC)"
            case .toMP4AV1: " (AV1)"
            case .toProRes: " (ProRes)"
            default: ""
            }
        }

        var outputExtension: String? {
            switch self {
            case .compressVideo, .toMP4, .toMP4HEVC, .toMP4AV1, .makeVertical, .to1080p, .to720p, .muteVideo, .speedUp: "mp4"
            case .toWebM, .toWebMAV1: "webm"
            case .toProRes: "mov"
            case .toMKV: "mkv"
            case .toGIF: "gif"
            case .audioM4A, .toM4A: "m4a"
            case .audioMP3, .toMP3: "mp3"
            case .audioWAV, .toWAV: "wav"
            case .toFLAC: "flac"
            case .toAIFF: "aiff"
            case .toJPEG, .youtubeThumbnail, .forWeb: "jpg"
            case .toPNG: "png"
            case .toHEIC: "heic"
            case .toWebP: "webp"
            case .toTIFF: "tiff"
            case .halfSize, .quarterSize, .normalizeLoudness, .trimSilence: nil // keeps its type
            }
        }

        /// A change of format, pointless on a file already in it. A codec choice isn't: an MP4 can
        /// become an HEVC MP4.
        var isFormatChange: Bool { !isEdit && outputExtension != nil && ![.toMP4HEVC, .toMP4AV1, .toProRes].contains(self) }

        /// Streams already in the codec this asks for are copied into the new container, not
        /// encoded again: seconds instead of minutes, and nothing lost.
        var copiesMatchingStreams: Bool { [.toMP4, .toMP4HEVC, .toMP4AV1].contains(self) }

        var usesFFmpeg: Bool { ![.toJPEG, .toPNG, .toHEIC, .toTIFF, .halfSize, .quarterSize, .forWeb, .toWebP].contains(self) }

        /// Encoded on the Mac's media engine. It turns some files down (H.264 above 4K), and those
        /// go again with libx264.
        var usesHardwareEncoder: Bool { [.compressVideo, .toMP4, .toMP4HEVC, .toProRes, .makeVertical, .to1080p, .to720p, .speedUp].contains(self) }

        /// A word under the menu item, for the choice that trades something away.
        var note: String? {
            switch self {
            case .toMP4HEVC: "Keeps 10-bit and HDR · some Windows PCs need a codec"
            case .toMP4AV1: "Smallest · plays on M3, A17 Pro and newer, and browsers"
            case .toWebMAV1: "Faster than VP9 · browsers only, not iPhone or iPad apps"
            case .toProRes: "Very large · for editing"
            case .toMKV: "Nothing re-encoded · Apple's apps can't open it"
            default: nil
            }
        }
    }

    enum Kind { case video, audio, image }

    /// Where the result goes: beside the original under its own name ("Clip (compressed).mp4"),
    /// beside it under the original's name with the new extension, or in the original's place
    /// with the original in the Trash (only once the conversion has worked).
    enum Saving: Equatable { case copy, sameName, replace }

    struct Job: Identifiable, Equatable {
        enum State: Equatable { case queued, running, done(URL), failed(String) }
        let id = UUID()
        let source: URL
        let operation: Operation
        /// Files converted together share one; they finish with one notice.
        var batch: UUID?
        var state: State = .queued
        var progress: Double?
        var saving: Saving = .copy
        /// The media engine turned it down; this go uses the CPU.
        var software = false
        /// Measured when it starts: a replaced original is in the Trash by the end.
        var sourceSize: Int64 = 0
        var isActive: Bool { state == .queued || state == .running }
    }

    /// A batch as the shelf shows it: how far along all of its files are.
    struct BatchStatus: Identifiable {
        let id: UUID
        let operation: Operation
        let total: Int
        let finished: Int
        let progress: Double?
        let jobs: [Job]
    }

    @Published private(set) var jobs: [Job] = []
    private var processes: [UUID: Process] = [:]
    /// Outputs being written now: two at once (photo.heic and photo.tiff to WebP) mustn't pick the same free name.
    private var reserved: Set<String> = []

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
        case .video: all = [.compressVideo, .toGIF, .makeVertical, .toMP4, .toMP4HEVC, .toMP4AV1, .toWebM, .toWebMAV1, .toProRes, .toMKV, .audioM4A, .audioMP3, .audioWAV,
                            .to1080p, .to720p, .muteVideo, .speedUp]
        case .audio: all = [.toMP3, .toM4A, .normalizeLoudness, .toWAV, .toFLAC, .toAIFF, .trimSilence]
        case .image: all = [.toJPEG, .toPNG, .toHEIC, .toWebP, .toTIFF, .halfSize, .forWeb, .quarterSize, .youtubeThumbnail]
        }
        return all.filter { op in
            guard (ffmpeg || !op.usesFFmpeg) && !(op.isFormatChange && exts == [op.outputExtension ?? ""]) else { return false }
            switch op {
            // WebP comes from Homebrew's cwebp (macOS can't write it), or gif2webp for a moving GIF.
            case .toWebP: return cwebp != nil && urls.allSatisfy(canMakeWebP)
            case .halfSize, .quarterSize: return urls.allSatisfy(canResize)
            default: return true
            }
        }
    }

    nonisolated static let cwebp: String? = ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"].first { FileManager.default.isExecutableFile(atPath: $0) }
    nonisolated static let gif2webp: String? = ["/opt/homebrew/bin/gif2webp", "/usr/local/bin/gif2webp"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// The image types macOS can save (sips writes these; it reads more, WebP and SVG among them).
    nonisolated private static let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    nonisolated private static func isWritable(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased()).map { writableTypes.contains($0.identifier) } ?? false
    }

    /// More than one frame: a moving GIF, an animated WebP or PNG.
    nonisolated static func isAnimated(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    nonisolated private static func ext(_ url: URL) -> String { url.pathExtension.lowercased() }

    /// Half and quarter size keep the file's format, so it must be one that can be written back:
    /// a moving GIF through ffmpeg (sips would keep only its first frame), WebP through cwebp, and
    /// never SVG, which has no pixels to halve.
    nonisolated private static func canResize(_ url: URL) -> Bool {
        if ext(url) == "svg" { return false }
        if isAnimated(url) { return ext(url) == "gif" && VideoDownloader.ffmpeg != nil }
        return isWritable(url) || (ext(url) == "webp" && cwebp != nil)
    }

    /// Any still picture (through PNG when cwebp can't read it); a moving one only as a GIF, with gif2webp.
    nonisolated private static func canMakeWebP(_ url: URL) -> Bool {
        isAnimated(url) ? ext(url) == "gif" && gif2webp != nil : true
    }

    /// The conversions these files can take that you reach for most, for one-drop targets: the
    /// ones you've used most for this kind of file, topped up from the usual order.
    static func quick(for urls: [URL], limit: Int = 3) -> [Operation] {
        let ops = operations(for: urls)
        let usage = UserDefaults.standard.dictionary(forKey: usageKey) as? [String: Int] ?? [:]
        let ranked = ops.enumerated().sorted { a, b in
            let ua = usage[a.element.rawValue] ?? 0, ub = usage[b.element.rawValue] ?? 0
            return ua != ub ? ua > ub : a.offset < b.offset
        }
        return Array(ranked.map(\.element).prefix(limit))
    }

    private static let usageKey = "convert.usage"

    private static func used(_ op: Operation) {
        var usage = UserDefaults.standard.dictionary(forKey: usageKey) as? [String: Int] ?? [:]
        usage[op.rawValue, default: 0] += 1
        UserDefaults.standard.set(usage, forKey: usageKey)
    }

    /// A menu at the pointer with what these files can become: new formats, then changes that
    /// keep the format.
    func offer(_ urls: [URL]) {
        let ops = Self.operations(for: urls)
        guard !ops.isEmpty else {
            let anyMedia = urls.contains { Self.kind(of: $0) != nil }
            ActivityCenter.shared.show(.notice(title: anyMedia && VideoDownloader.ffmpeg == nil ? "Install ffmpeg to convert video" : "Nothing to convert",
                                               detail: anyMedia ? "brew install ffmpeg" : "Videos, audio and images", icon: "wand.and.stars", tone: .warning), for: 3)
            return
        }
        let item = { (op: Operation) -> PopUpMenu.Item in (op.title, op.symbol, { MediaConverter.shared.convert(urls, op) }) }
        PopUpMenu.show(sections: [ops.filter { !$0.isEdit }.map(item), ops.filter(\.isEdit).map(item)],
                       title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files",
                       notes: Dictionary(uniqueKeysWithValues: ops.compactMap { op in op.note.map { (op.title, $0) } }))
    }

    /// Converts every file; more than a few at once wait their turn.
    func convert(_ urls: [URL], _ operation: Operation, saving: Saving = .copy) {
        let files = urls.filter { Self.kind(of: $0) != nil }
        guard !files.isEmpty else { return }
        Self.used(operation)
        let batch = files.count > 1 ? UUID() : nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            for url in files { jobs.insert(Job(source: url, operation: operation, batch: batch, saving: saving), at: 0) }
        }
        pump()
    }

    func cancel(_ job: Job) {
        // Queued, or still looking at its streams before ffmpeg starts.
        guard let process = processes[job.id] else { dismiss(job); return }
        process.terminate()
    }

    /// Stops a batch: what's waiting is dropped, what's running is stopped.
    func cancel(batch: UUID) {
        for job in jobs where job.batch == batch && job.isActive { cancel(job) }
    }

    /// Batches (and single files) still at work, newest first.
    var activeBatches: [BatchStatus] {
        var order: [UUID] = []
        var groups: [UUID: [Job]] = [:]
        for job in jobs {
            let key = job.batch ?? job.id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(job)
        }
        return order.compactMap { key in
            let group = groups[key]!
            guard group.contains(where: \.isActive) else { return nil }
            let finished = group.filter { !$0.isActive }.count
            let progress = group.count == 1 ? group[0].progress
                : group.reduce(0.0) { $0 + ($1.isActive ? ($1.progress ?? 0) : 1) } / Double(group.count)
            return BatchStatus(id: key, operation: group[0].operation, total: group.count, finished: finished, progress: progress, jobs: group)
        }
    }

    /// ffmpeg already uses every core; images are quick.
    private func pump() {
        let running = jobs.filter { $0.state == .running }
        let ffmpegRunning = running.filter(\.operation.usesFFmpeg).count
        let otherRunning = running.count - ffmpegRunning
        var ffmpegRoom = 2 - ffmpegRunning, otherRoom = 4 - otherRunning
        for job in jobs.reversed() where job.state == .queued {
            if job.operation.usesFFmpeg {
                guard ffmpegRoom > 0 else { continue }
                ffmpegRoom -= 1
            } else {
                guard otherRoom > 0 else { continue }
                otherRoom -= 1
            }
            start(job)
        }
    }

    func dismiss(_ job: Job) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { jobs.removeAll { $0.id == job.id } }
    }

    // MARK: - Run

    private func start(_ job: Job) {
        let source = job.source, op = job.operation, id = job.id, software = job.software
        let output = Self.outputURL(for: source, op, keepingName: job.saving == .sameName, avoiding: reserved)
        reserved.insert(output.path)
        let size = Cleaner.allocatedSize(source)
        update(id) { $0.state = .running; $0.progress = op.usesFFmpeg ? 0 : nil; $0.sourceSize = size }

        if Self.kind(of: source) == .image {
            guard let (tool, args) = Self.imageCommand(op, source: source, output: output) else {
                update(id) { $0.state = .failed(op.usesFFmpeg ? "Needs ffmpeg" : "Can't do this one") }
                reserved.remove(output.path)
                return
            }
            run(id, source: source, op: op, output: output, tool: tool, args: args, tracksProgress: false)
        } else if op.copiesMatchingStreams {
            // What's inside decides between copying and encoding; ffprobe takes a moment, off the main thread.
            Task.detached {
                let streams = Self.streams(of: source)
                await MediaConverter.shared.startFFmpeg(id, source: source, op: op, output: output, software: software, streams: streams)
            }
        } else {
            startFFmpeg(id, source: source, op: op, output: output, software: software, streams: nil)
        }
    }

    private func startFFmpeg(_ id: UUID, source: URL, op: Operation, output: URL, software: Bool, streams: Streams?) {
        guard jobs.contains(where: { $0.id == id && $0.state == .running }) else {
            // Cancelled while its streams were being read.
            reserved.remove(output.path)
            pump()
            return
        }
        guard let ffmpeg = VideoDownloader.ffmpeg else {
            update(id) { $0.state = .failed("Needs ffmpeg") }
            reserved.remove(output.path)
            return
        }
        // Decoded on the media engine too, where it can (ffmpeg falls back to the CPU by itself).
        let decode = Self.kind(of: source) == .video ? ["-hwaccel", "videotoolbox"] : []
        let args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + decode + ["-i", source.path]
            + Self.ffmpegArgs(op, source: source, software: software, streams: streams)
            + ["-progress", "pipe:1", "-nostats", output.path]
        run(id, source: source, op: op, output: output, tool: ffmpeg, args: args, tracksProgress: true)
    }

    private func run(_ id: UUID, source: URL, op: Operation, output: URL, tool: URL, args: [String], tracksProgress: Bool) {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        // What went wrong, if it does (the last few lines are plenty).
        let err = Pipe()
        let errors = ErrorTail()
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errors.append(data) }
        }
        if tracksProgress {
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
            err.fileHandleForReading.readabilityHandler = nil
            let ok = proc.terminationStatus == 0
            let cancelled = proc.terminationReason == .uncaughtSignal
            let reason = ok ? nil : Self.reason(errors.text, op: op)
            Task { @MainActor in MediaConverter.shared.finished(id, output: output, ok: ok, cancelled: cancelled, reason: reason) }
        }
        do {
            try p.run()
            processes[id] = p
        } catch {
            update(id) { $0.state = .failed("Couldn't start") }
            reserved.remove(output.path)
            pump()
        }
    }

    private var durations: [UUID: Double] = [:]

    private func progress(_ id: UUID, seconds: Double) {
        guard let total = durations[id], total > 0 else { return }
        update(id) { $0.progress = min(1, seconds / total) }
    }

    private func finished(_ id: UUID, output: URL, ok: Bool, cancelled: Bool, reason: String? = nil) {
        processes[id] = nil
        reserved.remove(output.path)
        durations[id] = nil
        defer { pump() }
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if cancelled {
            try? FileManager.default.removeItem(at: output)
            dismiss(job)
            return
        }
        guard ok, FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            if job.operation.usesHardwareEncoder, !job.software {
                update(id) { $0.state = .queued; $0.progress = nil; $0.software = true }
                return
            }
            update(id) { $0.state = .failed(reason ?? "\(job.operation.title) failed") }
            if job.batch == nil {
                let detail = reason.map { "\($0) · \(job.source.lastPathComponent)" } ?? job.source.lastPathComponent
                ActivityCenter.shared.show(.notice(title: "Conversion failed", detail: detail, icon: "wand.and.stars", tone: .warning), for: 4)
            } else {
                batchFinished(job)
            }
            return
        }
        let replaced = job.saving == .replace ? Self.replaceOriginal(job.source, with: output) : nil
        let result = replaced ?? output
        update(id) { $0.state = .done(result); $0.progress = 1 }
        // A replaced file on the shelf becomes the new one, where it was.
        if replaced != nil, ShelfStore.shared.replace(job.source, with: result) {
        } else if AppSettings.shared.shelfEnabled, AppSettings.shared.convertToShelf {
            ShelfStore.shared.add([result])
        }
        if job.batch != nil {
            batchFinished(job)
        } else {
            let sizes = Self.sizeChange(job.sourceSize, Cleaner.allocatedSize(result)) ?? result.lastPathComponent
            ActivityCenter.shared.show(.notice(title: job.operation.title.replacingOccurrences(of: "Convert to ", with: "Now "),
                                               detail: sizes, icon: "wand.and.stars"), for: 4)
        }
        // Finished conversions clear themselves after a while; the file is on the shelf.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if let job = self?.jobs.first(where: { $0.id == id }), !job.isActive { self?.dismiss(job) }
        }
    }

    /// "120 MB → 40 MB (−67%)", or nil when either size is unknown.
    private static func sizeChange(_ before: Int64, _ after: Int64) -> String? {
        guard before > 0, after > 0 else { return nil }
        let percent = Int((Double(after - before) / Double(before) * 100).rounded())
        let change = percent == 0 ? "same size" : percent < 0 ? "−\(-percent)%" : "+\(percent)%"
        return "\(formatBytes(before)) → \(formatBytes(after)) (\(change))"
    }

    /// The last file of a batch is done: one notice for all of them, with the space saved or spent.
    private func batchFinished(_ job: Job) {
        guard let batch = job.batch else { return }
        let group = jobs.filter { $0.batch == batch }
        guard !group.contains(where: \.isActive) else { return }
        let outputs = group.compactMap { if case .done(let url) = $0.state { url } else { nil } }
        let failed = group.count - outputs.count
        let before = group.filter { if case .done = $0.state { true } else { false } }.reduce(Int64(0)) { $0 + $1.sourceSize }
        let after = outputs.reduce(Int64(0)) { $0 + Int64(Cleaner.allocatedSize($1)) }
        var detail = Self.sizeChange(before, after) ?? ""
        if failed > 0 { detail = (detail.isEmpty ? "" : detail + " · ") + "\(failed) failed" }
        ActivityCenter.shared.show(.notice(title: "\(job.operation.shortTitle): \(outputs.count) of \(group.count) files", detail: detail,
                                           icon: "wand.and.stars", tone: failed > 0 ? .warning : .success), for: 4)
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[i]
        change(&job)
        if job != jobs[i] { jobs[i] = job }
    }

    // MARK: - Commands

    /// The first video and audio stream's codecs, as ffprobe names them ("h264", "aac").
    struct Streams: Sendable {
        var video: String?
        var pixelFormat: String?
        var audio: String?
    }

    nonisolated private static func streams(of url: URL) -> Streams? {
        guard let probe = VideoDownloader.ffmpeg?.deletingLastPathComponent().appendingPathComponent("ffprobe").path else { return nil }
        let result = Shell.runSync(probe, ["-v", "error", "-show_entries", "stream=codec_type,codec_name,pix_fmt:stream_disposition=attached_pic",
                                           "-of", "json", url.path], timeout: 10)
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any],
              let list = json["streams"] as? [[String: Any]] else { return nil }
        // Cover art counts as a video stream; it isn't the video.
        let video = list.first { $0["codec_type"] as? String == "video" && ($0["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1 }
        let audio = list.first { $0["codec_type"] as? String == "audio" }
        return Streams(video: video?["codec_name"] as? String, pixelFormat: video?["pix_fmt"] as? String, audio: audio?["codec_name"] as? String)
    }

    /// `software` is the second go at a job the media engine turned down. `streams` (for the
    /// conversions that copy what already fits) says what's inside.
    nonisolated private static func ffmpegArgs(_ op: Operation, source: URL, software: Bool = false, streams: Streams? = nil) -> [String] {
        // On the media engine: a few times faster than libx264 for a fraction of the CPU, about
        // the same quality (VMAF ~90 against x264 CRF 20's ~92), a little smaller.
        let h264Video = software ? ["-c:v", "libx264", "-crf", "20", "-preset", "medium"] : ["-c:v", "h264_videotoolbox", "-q:v", "65"]
        // Subtitles stay behind: picture ones (Blu-ray's) can't become MP4 text and would fail the lot.
        let mp4 = ["-sn", "-movflags", "+faststart"]
        let h264 = h264Video + ["-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"] + mp4
        // Sound an MP4 holds as it is goes in untouched; anything else becomes AAC.
        let mp4Audio = ["aac", "mp3", "alac", "ac3", "eac3"].contains(streams?.audio ?? "") ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
        switch op {
        case .compressVideo:
            // About a third of the size of a phone or screen recording, still sharp. HEVC on the
            // media engine comes out ~20% bigger than libx264 at CRF 26 for a quarter of the CPU.
            let video = software ? ["-c:v", "libx264", "-crf", "26", "-preset", "medium"] : ["-c:v", "hevc_videotoolbox", "-q:v", "52", "-tag:v", "hvc1"]
            return video + ["-pix_fmt", "yuv420p", "-vf", "scale='min(1920,iw)':-2", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
        case .toMP4:
            // Already 8-bit H.264 (an MKV, a MOV): only the container changes.
            if streams?.video == "h264", streams?.pixelFormat == "yuv420p" { return ["-c:v", "copy"] + mp4Audio + mp4 }
            return h264
        case .toMP4HEVC:
            // VideoToolbox HEVC is about as efficient as its H.264 here; what it adds is 10-bit, so HDR survives.
            if streams?.video == "hevc" { return ["-c:v", "copy", "-tag:v", "hvc1"] + mp4Audio + mp4 }
            let tenBit = streams?.pixelFormat.map { $0.contains("10") || $0.contains("12") } ?? false
            let video = software ? ["-c:v", "libx265", "-crf", "22", "-preset", "fast", "-x265-params", "log-level=error"]
                : ["-c:v", "hevc_videotoolbox", "-q:v", "62"] + (tenBit ? ["-profile:v", "main10"] : [])
            return video + ["-tag:v", "hvc1", "-pix_fmt", tenBit ? (software ? "yuv420p10le" : "p010le") : "yuv420p"] + mp4Audio + mp4
        case .toMP4AV1:
            // Apple plays AV1 in MP4 (never in WebM or MKV) on chips that decode it: M3, A17 Pro and later.
            if streams?.video == "av1" { return ["-c:v", "copy"] + mp4Audio + mp4 }
            return ["-c:v", "libsvtav1", "-crf", "30", "-preset", "8", "-pix_fmt", "yuv420p"] + mp4Audio + mp4
        case .toProRes:
            // ProRes 422, on the media engine: big, but every editor opens it and scrubs it smoothly.
            let video = software ? ["-c:v", "prores_ks", "-profile:v", "2"] : ["-c:v", "prores_videotoolbox", "-profile:v", "standard"]
            return video + ["-c:a", "pcm_s16le"]
        case .toMKV:
            // Every stream as it is, subtitles too (MP4's text ones as SRT).
            return ["-map", "0:v", "-map", "0:a?", "-map", "0:s?", "-c", "copy", "-c:s", "srt"]
        case .makeVertical:
            // The middle of the frame at 9:16, 1080×1920, for Reels, TikTok and Shorts.
            return ["-vf", "crop='min(iw,ih*9/16)':ih,scale=1080:1920:flags=lanczos,setsar=1"] + h264
        case .to1080p:
            return ["-vf", "scale=-2:'min(1080,ih)':flags=lanczos"] + h264
        case .to720p:
            return ["-vf", "scale=-2:'min(720,ih)':flags=lanczos"] + h264
        case .muteVideo:
            return ["-c:v", "copy", "-an", "-movflags", "+faststart"]
        case .speedUp:
            return ["-vf", "setpts=PTS/2", "-af", "atempo=2"] + h264
        case .trimSilence:
            // Quiet at the start and the end only; pauses in the middle stay.
            let edge = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.2"
            return ["-vn", "-af", "\(edge),areverse,\(edge),areverse"] + Self.sameCodec(source)
        case .toWebM:
            // Macs have no VP9 encoder in hardware. Speed 4 with tiles is ~40% quicker than
            // libvpx's default for the same quality; 8-bit, since a 10-bit source would otherwise
            // make profile 2 VP9, which plenty of players can't open.
            return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-deadline", "good", "-cpu-used", "4", "-row-mt", "1", "-tile-columns", "2",
                    "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "128k"]
        case .toWebMAV1:
            // SVT-AV1: VP9's quality several times faster and a little smaller. Every current
            // browser plays it; older Safari (before 17) and Macs without AV1 decoding (before M3)
            // may not, or only in software.
            return ["-c:v", "libsvtav1", "-crf", "30", "-preset", "8", "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "128k"]
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
            return ["-vn", "-af", "loudnorm=I=-14:TP=-1:LRA=11"] + Self.sameCodec(source)
        case .toWebP: return ["-c:v", "libwebp", "-quality", "85", "-frames:v", "1"]
        case .youtubeThumbnail:
            // Filled to 16:9 and cropped, well under YouTube's 2 MB.
            return ["-vf", "scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720", "-q:v", "3", "-frames:v", "1"]
        case .toJPEG, .toPNG, .toHEIC, .toTIFF, .halfSize, .quarterSize, .forWeb: return []
        }
    }

    /// Audio written back in the format it came in.
    nonisolated private static func sameCodec(_ source: URL) -> [String] {
        switch source.pathExtension.lowercased() {
        case "mp3": ["-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a", "aac": ["-c:a", "aac", "-b:a", "256k"]
        case "flac": ["-c:a", "flac"]
        case "aif", "aiff": ["-c:a", "pcm_s16be"]
        // Ogg can't hold plain PCM; Opus is what this ffmpeg can write into it (it has no Vorbis).
        case "ogg", "oga", "opus": ["-c:a", "libopus", "-b:a", "160k"]
        default: ["-c:a", "pcm_s16le"]
        }
    }

    /// How an image becomes its result: one tool, or a two-step `sh` script when a format needs a
    /// stop on the way (sips reads WebP and SVG but can't write them; cwebp reads only PNG and
    /// JPEG; ffmpeg can't read SVG). The paths go in as the script's arguments, never into its text.
    nonisolated private static func imageCommand(_ op: Operation, source: URL, output: URL) -> (URL, [String])? {
        let sips = "/usr/bin/sips"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notch-convert-\(UUID().uuidString).png").path
        /// A plain `sh` script given the source, the output, a PNG on the way and the second tool
        /// as `$in`, `$out`, `$tmp` and `$tool` (and anything after as `"$@"`); the PNG is removed after.
        func pipeline(_ script: String, tool: String, _ rest: [String] = []) -> (URL, [String]) {
            let body = #"in="$1"; out="$2"; tmp="$3"; tool="$4"; shift 4"# + "\n" + script + "\n" + #"s=$?; rm -f "$tmp"; exit $s"#
            return (URL(fileURLWithPath: "/bin/sh"), ["-c", body, "sh", source.path, output.path, tmp, tool] + rest)
        }
        let ext = ext(source)
        switch op {
        case .toWebP:
            if isAnimated(source), let gif2webp { return (URL(fileURLWithPath: gif2webp), ["-quiet", "-q", "85", source.path, "-o", output.path]) }
            guard let cwebp else { return nil }
            if ["png", "jpg", "jpeg"].contains(ext) { return (URL(fileURLWithPath: cwebp), ["-quiet", "-q", "85", source.path, "-o", output.path]) }
            return pipeline(#"\#(sips) -s format png "$in" --out "$tmp" >/dev/null && "$tool" -quiet -q 85 "$tmp" -o "$out""#, tool: cwebp)
        case .halfSize, .quarterSize:
            let divisor = op == .halfSize ? 2 : 4
            if isAnimated(source) {
                // Every frame, scaled, with a palette made for the smaller picture.
                guard let ffmpeg = VideoDownloader.ffmpeg else { return nil }
                return (ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", source.path, "-vf",
                                 "scale=iw/\(divisor):-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse", "-loop", "0", output.path])
            }
            if ext == "webp", let cwebp {
                // sipsArgs here is only "--resampleWidth N" or "-Z N": numbers, safe in the script's text.
                let resize = sipsArgs(op, source: source).joined(separator: " ")
                return pipeline(#"\#(sips) \#(resize) -s format png "$in" --out "$tmp" >/dev/null && "$tool" -quiet -q 90 "$tmp" -o "$out""#, tool: cwebp)
            }
            return (URL(fileURLWithPath: sips), sipsArgs(op, source: source) + [source.path, "--out", output.path])
        case .youtubeThumbnail:
            guard let ffmpeg = VideoDownloader.ffmpeg else { return nil }
            let args = ffmpegArgs(op, source: source)
            if ext == "svg" {
                return pipeline(#"\#(sips) -s format png "$in" --out "$tmp" >/dev/null && "$tool" -hide_banner -nostdin -y -loglevel error -i "$tmp" "$@" "$out""#,
                                tool: ffmpeg.path, args)
            }
            return (ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", source.path] + args + [output.path])
        default:
            return (URL(fileURLWithPath: sips), sipsArgs(op, source: source) + [source.path, "--out", output.path])
        }
    }

    /// A failure in words, from what the tool said, when it's one people can do something about.
    nonisolated private static func reason(_ errors: String, op: Operation) -> String? {
        if errors.contains("does not contain any stream"), [.audioM4A, .audioMP3, .audioWAV].contains(op) { return "This video has no sound" }
        if errors.contains("Can't write format") { return "macOS can't save this format" }
        if errors.contains("no decoder found") || errors.contains("Invalid data found when processing input") { return "Couldn't read this file" }
        if errors.contains("No space left") { return "The disk is full" }
        return nil
    }

    nonisolated private static func sipsArgs(_ op: Operation, source: URL) -> [String] {
        switch op {
        case .toJPEG: return ["-s", "format", "jpeg", "-s", "formatOptions", "85"]
        case .toPNG: return ["-s", "format", "png"]
        case .toHEIC: return ["-s", "format", "heic", "-s", "formatOptions", "80"]
        case .toTIFF: return ["-s", "format", "tiff"]
        case .halfSize, .quarterSize:
            let width = NSImageRep(contentsOf: source)?.pixelsWide ?? 0
            let divisor = op == .halfSize ? 2 : 4
            return width > 1 ? ["--resampleWidth", String(max(1, width / divisor))] : ["-Z", op == .halfSize ? "1024" : "512"]
        case .forWeb:
            // Longest side 2048 (never enlarged), JPEG at 80: sharp on a Retina page, a fraction of the size.
            let rep = NSImageRep(contentsOf: source)
            let side = max(rep?.pixelsWide ?? 0, rep?.pixelsHigh ?? 0)
            return ["-s", "format", "jpeg", "-s", "formatOptions", "80"] + (side > 2048 || side == 0 ? ["-Z", "2048"] : [])
        default: return []
        }
    }

    /// The ways these files can be saved after `op`, for the picker's second step. The original's
    /// own name only when the extension changes (it would clash otherwise), and never replacing
    /// a video with what was taken out of it.
    static func savings(for urls: [URL], _ op: Operation) -> [Saving] {
        var all: [Saving] = [.copy]
        if !op.suffix.isEmpty, let ext = op.outputExtension, urls.allSatisfy({ Self.ext($0) != ext }) { all.append(.sameName) }
        if ![.audioM4A, .audioMP3, .audioWAV, .youtubeThumbnail].contains(op) { all.append(.replace) }
        return all
    }

    /// What the result will be called, to show before it's made.
    static func previewName(for source: URL, _ op: Operation, _ saving: Saving) -> String {
        let base = source.deletingPathExtension().lastPathComponent + (saving == .copy ? op.suffix : "")
        return base + "." + (op.outputExtension ?? source.pathExtension)
    }

    /// The original to the Trash and the result under its name (with its own extension). Nil when
    /// the original is untouched: the result was saved elsewhere (a folder it can't write to), or
    /// the Trash said no. If another file already has the name, the result keeps the one it has.
    nonisolated private static func replaceOriginal(_ source: URL, with output: URL) -> URL? {
        let fm = FileManager.default
        guard output.deletingLastPathComponent().standardizedFileURL == source.deletingLastPathComponent().standardizedFileURL,
              (try? fm.trashItem(at: source, resultingItemURL: nil)) != nil else { return nil }
        let target = source.deletingPathExtension().appendingPathExtension(output.pathExtension)
        guard !fm.fileExists(atPath: target.path), (try? fm.moveItem(at: output, to: target)) != nil else { return output }
        return target
    }

    /// "Clip.mov" → "Clip (compressed).mp4" (or "Clip.mp4" when keeping the name), numbered if that name is taken.
    nonisolated private static func outputURL(for source: URL, _ op: Operation, keepingName: Bool = false, avoiding reserved: Set<String> = []) -> URL {
        let folder = source.deletingLastPathComponent()
        let writable = FileManager.default.isWritableFile(atPath: folder.path)
        let dir = writable ? folder : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = source.deletingPathExtension().lastPathComponent + (keepingName ? "" : op.suffix)
        let ext = op.outputExtension ?? source.pathExtension
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || url == source || reserved.contains(url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}

/// The end of what a tool wrote to stderr, gathered as it comes (from a background thread).
private final class ErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > 8192 { data = data.suffix(4096) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
