import AVFoundation
import AppKit
import SwiftUI

/// Live captions and call transcripts. Captions (turned on by hand) show what the Mac is playing as
/// text in a strip under the notch. A call being transcribed (Settings → Home → Record
/// calls) listens to both sides, the call's audio as "Them" and the microphone as "You", and keeps
/// the transcript for notes afterwards. Everything is turned into text on this Mac.
@MainActor
final class LiveCaptions: ObservableObject {
    static let shared = LiveCaptions()

    enum Speaker: String, Codable { case them, you }

    struct Line: Identifiable, Codable, Equatable {
        var id = UUID()
        let speaker: Speaker
        let text: String
        let at: Date
        /// Where it starts and ends in the recording, in seconds (none in calls kept before there was audio).
        var offset: TimeInterval? = nil
        var end: TimeInterval? = nil
        /// Which of the other side's voices said it (1, 2…), once the call's been listened to again.
        var voice: Int? = nil
    }

    /// Finished stretches of speech, in order.
    @Published private(set) var lines: [Line] = []
    /// What's being said right now, per side (it firms up into a line).
    @Published private(set) var partial: [Speaker: String] = [:]
    /// The strip under the notch is showing.
    @Published private(set) var showing = false {
        didSet { if CaptionStrip.shared.showing != showing { CaptionStrip.shared.showing = showing } }
    }
    /// A call is being transcribed and kept.
    @Published private(set) var recording = false
    /// Getting ready: the speech model downloading, the first start.
    @Published private(set) var preparing = false
    @Published private(set) var problem: String?

    private var systemSource: SystemAudioSource?
    private var micSource: MicSource?
    /// A file standing in for the call's other side (debug).
    private var fileSource: Task<Void, Never>?
    private var streams: [Speaker: AnyObject] = [:]
    private var tees: [Speaker: SourceTee] = [:]
    /// The call's sound going to disk, and the words to listen for.
    private var session: MeetingRecording?
    private var vocabulary: [String] = []
    private var lastJournal = Date.distantPast
    private var stopping = false

    static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    var transcript: String {
        lines.map { "\($0.speaker == .you ? "You" : "Them"): \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Captions (by hand)

    func toggleCaptions() { showing ? stopCaptions() : startCaptions() }

    func startCaptions() {
        guard !showing else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showing = true }
        if !recording { lines = []; partial = [:] }
        Task { await listen(to: .them) }
    }

    func stopCaptions() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showing = false }
        if !recording { Task { await stopAll() } }
    }

    // MARK: - A call

    /// The sides of a call, transcribed and kept (sound and words) in `session`. Captions show
    /// too if they're on. `vocabulary`: names it should expect to hear.
    func startRecording(_ session: MeetingRecording, sides: [Speaker], vocabulary: [String] = []) {
        guard !recording else { return }
        recording = true
        lines = []
        partial = [:]
        self.session = session
        self.vocabulary = vocabulary
        lastJournal = Date()
        tees.values.forEach { $0.connect(session) }
        Task {
            for side in sides { await listen(to: side) }
        }
    }

    /// Stops and hands back the transcript, each line placed in the recording.
    func stopRecording() async -> [Line] {
        guard recording, !stopping else { return [] }
        // The last words come in as the transcribers finish, still placed in the recording.
        stopping = true
        await stopSide(.you)
        if !showing { await stopAll() } else { flushPartial(.them) }
        recording = false
        stopping = false
        tees.values.forEach { $0.connect(nil) }
        let kept = Echo.removed(from: lines)
        session?.note(kept)
        session?.finish()
        session = nil
        vocabulary = []
        return kept
    }

    /// Debug: a sound file plays the call's other side, in real time, instead of the Mac's audio.
    func debugFeed(_ url: URL) {
        guard #available(macOS 26, *), let file = try? AVAudioFile(forReading: url) else {
            problem = "Couldn't read \(url.lastPathComponent)"
            return
        }
        Task {
            if streams[.them] == nil {
                guard let stream = try? await SpeechStream.make(context: vocabulary, onText: { text, final, began in
                    Task { @MainActor in LiveCaptions.shared.heard(text, final: final, began: began, from: .them) }
                }) else { return }
                streams[.them] = stream
            }
            guard let stream = streams[.them] as? SpeechStream else { return }
            let tee = tee(.them)
            let format = file.processingFormat
            fileSource = Task.detached {
                let chunk = AVAudioFrameCount(format.sampleRate / 10)
                while !Task.isCancelled, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 {
                    stream.append(buffer)
                    tee.pass(buffer)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    // MARK: - Listening

    private func tee(_ speaker: Speaker) -> SourceTee {
        if let t = tees[speaker] { return t }
        let t = SourceTee(side: speaker)
        if recording { t.connect(session) }
        tees[speaker] = t
        return t
    }

    private func listen(to speaker: Speaker) async {
        guard #available(macOS 26, *) else {
            problem = "Live captions need macOS 26 or later"
            return
        }
        guard streams[speaker] == nil else { return }
        if speaker == .you {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                problem = "Allow the microphone for NotchApp in System Settings to transcribe your side"
                return
            }
        } else if !AudioSpectrum.permitted {
            problem = "Allow System Audio Recording for NotchApp to caption what's playing"
            AudioCapturePermission.request { _ in }
            return
        }
        preparing = true
        defer { preparing = false }
        do {
            let stream = try await SpeechStream.make(context: vocabulary) { text, final, began in
                Task { @MainActor in LiveCaptions.shared.heard(text, final: final, began: began, from: speaker) }
            }
            streams[speaker] = stream
            let tee = tee(speaker)
            switch speaker {
            case .them:
                systemSource = SystemAudioSource { stream.append($0); tee.pass($0) }
                if systemSource == nil { problem = "Couldn't listen to the Mac's sound" }
            case .you:
                micSource = MicSource { stream.append($0); tee.pass($0) }
                if micSource == nil { problem = "Couldn't listen to the microphone" }
            }
            if problem != nil, systemSource != nil || micSource != nil { problem = nil }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func stopSide(_ speaker: Speaker) async {
        switch speaker {
        case .them: systemSource?.invalidate(); systemSource = nil; fileSource?.cancel(); fileSource = nil
        case .you: micSource?.invalidate(); micSource = nil
        }
        tees[speaker]?.connect(nil)
        tees[speaker] = nil
        if #available(macOS 26, *), let stream = streams[speaker] as? SpeechStream { await stream.finish() }
        streams[speaker] = nil
        flushPartial(speaker)
    }

    private func stopAll() async {
        await stopSide(.them)
        await stopSide(.you)
    }

    private func flushPartial(_ speaker: Speaker) {
        if let text = partial[speaker], !text.isEmpty { add(Line(speaker: speaker, text: text, at: Date())) }
        partial[speaker] = nil
    }

    private func heard(_ text: String, final: Bool, began: Date?, from speaker: Speaker) {
        guard !text.isEmpty else { return }
        if final {
            partial[speaker] = nil
            guard let line = add(Line(speaker: speaker, text: text, at: began ?? Date())) else { return }
            // A long call keeps its transcript; captions alone keep what's on screen.
            if !recording, lines.count > 40 { lines.removeFirst(lines.count - 40) }
            if speaker == .them { MeetingAssistant.shared.heard(line) }
        } else {
            partial[speaker] = text
        }
    }

    /// A finished line, placed in the recording. While a call is kept, the microphone hearing the
    /// other side through the speakers isn't you: those lines are left out.
    @discardableResult
    private func add(_ raw: Line) -> Line? {
        var line = raw
        if recording, let start = session?.start {
            line.offset = max(0, line.at.timeIntervalSince(start))
            line.end = max(line.offset ?? 0, Date().timeIntervalSince(start))
            let recent = lines.suffix(30)
            switch line.speaker {
            case .you:
                if recent.contains(where: { $0.speaker == .them && Echo.near(line, $0, window: 6) && Echo.repeats(line.text, $0.text) }) {
                    return nil
                }
            case .them:
                // The echo can be finished first.
                let echoes = Set(recent.filter { $0.speaker == .you && Echo.near($0, line, window: 6) && Echo.repeats($0.text, line.text) }.map(\.id))
                if !echoes.isEmpty { lines.removeAll { echoes.contains($0.id) } }
            }
        }
        lines.append(line)
        if recording, Date().timeIntervalSince(lastJournal) > 15 {
            lastJournal = Date()
            session?.note(lines)
        }
        return line
    }
}

/// Whether the caption strip hangs under the notch, apart from the words themselves: the notch's
/// size follows this, and shouldn't redraw for every word.
@MainActor
final class CaptionStrip: ObservableObject {
    static let shared = CaptionStrip()
    @Published var showing = false
    static let height: CGFloat = 52
}
