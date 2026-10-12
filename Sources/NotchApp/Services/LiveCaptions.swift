import AVFoundation
import AppKit
import SwiftUI

/// Live captions and call transcripts. Captions (turned on by hand) show what the Mac is playing as
/// text in a strip under the notch. A call being transcribed (Settings → Calendar → Transcribe
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
    }

    /// Finished stretches of speech, in order.
    @Published private(set) var lines: [Line] = []
    /// What's being said right now, per side (it firms up into a line).
    @Published private(set) var partial: [Speaker: String] = [:]
    /// The strip under the notch is showing.
    @Published private(set) var showing = false {
        didSet { if CaptionStrip.shared.showing != showing { CaptionStrip.shared.showing = showing } }
    }
    /// A call is being transcribed (both sides).
    @Published private(set) var recording = false
    /// Getting ready: the speech model downloading, the first start.
    @Published private(set) var preparing = false
    @Published private(set) var problem: String?

    private var systemSource: SystemAudioSource?
    private var micSource: MicSource?
    private var streams: [Speaker: AnyObject] = [:]
    private var startedAt: Date?

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

    /// Both sides of a call, kept for notes. Captions show too if they're on.
    func startRecording() {
        guard !recording else { return }
        recording = true
        lines = []
        partial = [:]
        startedAt = Date()
        Task {
            await listen(to: .them)
            await listen(to: .you)
        }
    }

    /// Stops and hands back the transcript.
    func stopRecording() async -> [Line] {
        guard recording else { return [] }
        recording = false
        await stopSide(.you)
        if !showing { await stopAll() } else { flushPartial(.you) }
        let kept = lines
        return kept
    }

    // MARK: - Listening

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
            let stream = try await SpeechStream.make { text, final in
                Task { @MainActor in LiveCaptions.shared.heard(text, final: final, from: speaker) }
            }
            streams[speaker] = stream
            switch speaker {
            case .them:
                systemSource = SystemAudioSource { stream.append($0) }
                if systemSource == nil { problem = "Couldn't listen to the Mac's sound" }
            case .you:
                micSource = MicSource { stream.append($0) }
                if micSource == nil { problem = "Couldn't listen to the microphone" }
            }
            if problem != nil, systemSource != nil || micSource != nil { problem = nil }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func stopSide(_ speaker: Speaker) async {
        switch speaker {
        case .them: systemSource?.invalidate(); systemSource = nil
        case .you: micSource?.invalidate(); micSource = nil
        }
        if #available(macOS 26, *), let stream = streams[speaker] as? SpeechStream { await stream.finish() }
        streams[speaker] = nil
        flushPartial(speaker)
    }

    private func stopAll() async {
        await stopSide(.them)
        await stopSide(.you)
    }

    private func flushPartial(_ speaker: Speaker) {
        if let text = partial[speaker], !text.isEmpty { lines.append(Line(speaker: speaker, text: text, at: Date())) }
        partial[speaker] = nil
    }

    private func heard(_ text: String, final: Bool, from speaker: Speaker) {
        guard !text.isEmpty else { return }
        if final {
            partial[speaker] = nil
            let line = Line(speaker: speaker, text: text, at: Date())
            lines.append(line)
            // A long call keeps its transcript; captions alone keep what's on screen.
            if !recording, lines.count > 40 { lines.removeFirst(lines.count - 40) }
            if speaker == .them { MeetingAssistant.shared.heard(line) }
        } else {
            partial[speaker] = text
        }
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
