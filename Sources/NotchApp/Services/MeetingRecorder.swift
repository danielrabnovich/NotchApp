import AVFoundation
import AudioToolbox
import Foundation

/// One side of a call kept as sound: mono AAC at 24 kHz in an ADTS stream. ADTS frames each carry
/// their own header, so a file cut short by a crash still plays up to its last frame, with nothing
/// to finish. Buffers arrive in any format on any thread; they're converted and written on a
/// queue of the writer's own. Time the source didn't deliver (it started late, a device switched)
/// is written as silence, so both sides stay lined up with the clock from the recording's start.
final class TrackWriter: @unchecked Sendable {
    static let sampleRate: Double = 24_000
    private static let bitRate: UInt32 = 48_000

    private var file: ExtAudioFileRef?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TrackWriter.sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let queue = DispatchQueue(label: "com.notchapp.track", qos: .utility)
    private let start: Date
    /// Frames written so far, silence included.
    private var written: Int64 = 0

    init?(url: URL, start: Date) {
        self.start = start
        var aac = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                              mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                              mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var ref: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAAC_ADTSType, &aac, nil, AudioFileFlags.eraseFile.rawValue, &ref) == noErr,
              let ref else { return nil }
        var client = format.streamDescription.pointee
        guard ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr
        else { ExtAudioFileDispose(ref); return nil }
        // Speech doesn't need the encoder's default rate.
        var codec: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        if ExtAudioFileGetProperty(ref, kExtAudioFileProperty_AudioConverter, &size, &codec) == noErr, let codec {
            var rate = Self.bitRate
            if AudioConverterSetProperty(codec, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate) == noErr {
                // A null config tells the file to pick up the converter's new settings.
                var config: UnsafeRawPointer?
                ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<UnsafeRawPointer?>.size), &config)
            }
        }
        file = ref
    }

    /// Audio in, any format; `arrived` is when the buffer's last frame was heard.
    func append(_ buffer: AVAudioPCMBuffer, arrived: Date = Date()) {
        queue.async { [self] in
            guard let file, buffer.frameLength > 0 else { return }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
                converter?.downmix = true
            }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return }
            // Where this buffer belongs on the clock: anything missing before it is silence (a
            // quarter second of slack for scheduling; at most five minutes at once).
            let due = Int64((arrived.timeIntervalSince(start) * format.sampleRate).rounded()) - Int64(out.frameLength)
            let gap = due - written
            if gap > Int64(format.sampleRate / 4) { writeSilence(min(gap, Int64(format.sampleRate * 300)), to: file) }
            write(out, to: file)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, to file: ExtAudioFileRef) {
        if ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList) == noErr { written += Int64(buffer.frameLength) }
    }

    private func writeSilence(_ frames: Int64, to file: ExtAudioFileRef) {
        var left = frames
        while left > 0 {
            let n = AVAudioFrameCount(min(left, 24_000))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            silence.frameLength = n // zero-filled
            write(silence, to: file)
            left -= Int64(n)
        }
    }

    /// Writes what's queued and closes the file.
    func finish() {
        queue.sync {
            if let file { ExtAudioFileDispose(file) }
            file = nil
        }
    }

    deinit { if let file { ExtAudioFileDispose(file) } }
}

/// A call being kept: its folder (Meetings/<id>/), a track per side, and a journal of what's been
/// said so far, so a crash or a forced quit leaves a meeting to recover at the next launch.
final class MeetingRecording: @unchecked Sendable {
    /// What's written to `session.json` as the call goes.
    struct Journal: Codable {
        let id: UUID
        let title: String
        let app: String
        let started: Date
        /// When the tracks begin: line offsets count from here.
        let recordingStarted: Date
        var inPerson: Bool?
        var attendees: [String]?
        var lines: [LiveCaptions.Line]
    }

    let id: UUID
    let folder: URL
    let start = Date()
    private var tracks: [LiveCaptions.Speaker: TrackWriter] = [:]
    private var journal: Journal
    private let lock = NSLock()
    private let journalQueue = DispatchQueue(label: "com.notchapp.journal", qos: .utility)

    init(id: UUID, folder: URL, title: String, app: String, started: Date, sides: [LiveCaptions.Speaker], inPerson: Bool, attendees: [String]) {
        self.id = id
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        journal = Journal(id: id, title: title, app: app, started: started, recordingStarted: start, inPerson: inPerson ? true : nil,
                          attendees: attendees.isEmpty ? nil : attendees, lines: [])
        for side in sides {
            tracks[side] = TrackWriter(url: Self.trackURL(side, in: folder), start: start)
        }
        save(journal)
    }

    static func trackURL(_ side: LiveCaptions.Speaker, in folder: URL) -> URL {
        folder.appendingPathComponent(side == .them ? "them.aac" : "you.aac")
    }

    static func journalURL(in folder: URL) -> URL { folder.appendingPathComponent("session.json") }

    func append(_ buffer: AVAudioPCMBuffer, from side: LiveCaptions.Speaker, arrived: Date) {
        lock.lock()
        let track = tracks[side]
        lock.unlock()
        track?.append(buffer, arrived: arrived)
    }

    /// The lines so far, for the journal.
    func note(_ lines: [LiveCaptions.Line]) {
        journal.lines = lines
        save(journal)
    }

    func finish() {
        lock.lock()
        let all = tracks.values
        tracks = [:]
        lock.unlock()
        all.forEach { $0.finish() }
        // Written out; a meeting file takes over from the journal.
        journalQueue.sync {}
    }

    private func save(_ journal: Journal) {
        let url = Self.journalURL(in: folder)
        journalQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(journal) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// One side's audio on its way to its transcriber, teed into the recording. The source can start
/// before a recording does (captions already on), so the recording is plugged in and out while it runs.
final class SourceTee: @unchecked Sendable {
    private let lock = NSLock()
    private var recording: MeetingRecording?
    let side: LiveCaptions.Speaker

    init(side: LiveCaptions.Speaker) { self.side = side }

    func connect(_ recording: MeetingRecording?) {
        lock.lock()
        self.recording = recording
        lock.unlock()
    }

    func pass(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        lock.lock()
        let r = recording
        lock.unlock()
        r?.append(buffer, from: side, arrived: now)
    }
}

/// "You" lines that are really "Them": without headphones the microphone hears the other side
/// through the speakers, and its transcript repeats theirs a moment later.
enum Echo {
    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Most of `you`'s words, in order, are in `them`.
    static func repeats(_ you: String, _ them: String) -> Bool {
        let a = words(you), b = words(them)
        guard !a.isEmpty, !b.isEmpty else { return false }
        // A word or two: only if it's said the same, word for word.
        if a.count < 3 { return " \(b.joined(separator: " ")) ".contains(" \(a.joined(separator: " ")) ") }
        return Double(commonRun(a, b)) / Double(a.count) >= 0.75
    }

    /// The longest common subsequence of two word lists.
    private static func commonRun(_ a: [String], _ b: [String]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var row = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() { row[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], row[j]) }
            previous = row
        }
        return previous[b.count]
    }

    /// The lines without the "You" ones that echo a "Them" line said around the same time.
    static func removed(from lines: [LiveCaptions.Line], window: TimeInterval = 6) -> [LiveCaptions.Line] {
        let them = lines.filter { $0.speaker == .them }
        guard !them.isEmpty else { return lines }
        return lines.filter { line in
            guard line.speaker == .you else { return true }
            return !them.contains { other in near(line, other, window: window) && repeats(line.text, other.text) }
        }
    }

    /// Said within `window` seconds of each other (by their stretch of the recording when known).
    static func near(_ a: LiveCaptions.Line, _ b: LiveCaptions.Line, window: TimeInterval) -> Bool {
        if let s1 = a.offset, let s2 = b.offset {
            let e1 = a.end ?? s1, e2 = b.end ?? s2
            return s1 <= e2 + window && s2 <= e1 + window
        }
        return abs(a.at.timeIntervalSince(b.at)) <= window
    }
}

/// Plays a kept call back: both sides together, from any line.
@MainActor
final class MeetingPlayer: ObservableObject {
    static let shared = MeetingPlayer()

    @Published private(set) var meeting: UUID?
    @Published private(set) var playing = false
    /// Seconds into the recording.
    @Published private(set) var position: TimeInterval = 0
    private var players: [AVAudioPlayer] = []
    private var clock: Timer?

    var duration: TimeInterval { players.map(\.duration).max() ?? 0 }

    func play(_ id: UUID, from offset: TimeInterval) {
        if meeting != id {
            stop()
            players = MeetingAssistant.shared.tracks(id).values.compactMap { try? AVAudioPlayer(contentsOf: $0) }
            guard !players.isEmpty else { return }
            meeting = id
        }
        players.forEach { $0.pause(); $0.currentTime = max(0, offset); $0.prepareToPlay() }
        // Together: both start on the same tick of the output clock.
        let at = (players.first?.deviceCurrentTime ?? 0) + 0.08
        players.forEach { $0.play(atTime: at) }
        position = offset
        playing = true
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingPlayer.shared.tick() }
        }
    }

    /// Plays or pauses, picking up where it was.
    func toggle(_ id: UUID) {
        if playing, meeting == id { pause() } else { play(id, from: meeting == id ? position : 0) }
    }

    func pause() {
        players.forEach { $0.pause() }
        playing = false
        clock?.invalidate()
        clock = nil
    }

    func stop() {
        pause()
        players = []
        meeting = nil
        position = 0
    }

    private func tick() {
        position = players.map(\.currentTime).max() ?? 0
        if !players.contains(where: \.isPlaying) {
            pause()
            if position >= duration - 0.5 { position = 0 }
        }
    }
}
