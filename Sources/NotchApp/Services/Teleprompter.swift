import AVFoundation
import AppKit
import PDFKit
import SwiftUI

/// A teleprompter in the notch: your script right under the camera, so your eyes stay on the lens.
/// It moves at a steady pace (words a minute) or follows your voice word by word, waiting when you
/// pause. While it runs the notch stays open (even over a full-screen call) and the display awake.
@MainActor
final class Teleprompter: ObservableObject {
    static let shared = Teleprompter()

    @Published var script: String { didSet { UserDefaults.standard.set(script, forKey: "prompter.script"); words = Self.split(script) } }
    @Published var wordsPerMinute: Double { didSet { UserDefaults.standard.set(wordsPerMinute, forKey: "prompter.wpm") } }
    @Published var followsVoice: Bool { didSet { UserDefaults.standard.set(followsVoice, forKey: "prompter.voice"); if running { restartListening() } } }
    @Published var textSize: Double { didSet { UserDefaults.standard.set(textSize, forKey: "prompter.size") } }

    @Published private(set) var running = false
    @Published private(set) var paused = false
    /// How far through the script, in words (fractional while it glides between them).
    @Published private(set) var position: Double = 0
    @Published private(set) var listening = false
    @Published private(set) var words: [String] = []

    private var clock: Timer?
    private var lastTick = Date()
    private var awake: NSObjectProtocol?
    private var speech: AnyObject?
    private var mic: MicSource?
    /// Voice: the word the speech has reached, which `position` eases toward.
    private var voiceTarget: Double = 0

    static let paces: ClosedRange<Double> = 60...260
    static let sizes: ClosedRange<Double> = 16...40
    /// Voice following needs the on-device transcriber (macOS 26+).
    static var canFollowVoice: Bool { LiveCaptions.isSupported }

    private init() {
        let d = UserDefaults.standard
        script = d.string(forKey: "prompter.script") ?? ""
        wordsPerMinute = d.object(forKey: "prompter.wpm") as? Double ?? 140
        followsVoice = d.bool(forKey: "prompter.voice")
        textSize = d.object(forKey: "prompter.size") as? Double ?? 24
        words = Self.split(script)
    }

    static func split(_ text: String) -> [String] { text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    var progress: Double { words.isEmpty ? 0 : min(1, position / Double(words.count)) }

    /// About how long the script takes at the set pace.
    var duration: TimeInterval { Double(words.count) / max(1, wordsPerMinute) * 60 }

    // MARK: - Running

    func start(from word: Double = 0) {
        guard !words.isEmpty else { return }
        position = word
        voiceTarget = word
        paused = false
        running = true
        awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Teleprompter")
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { Teleprompter.shared.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        if followsVoice { startListening() }
        NotchPresenter.shared.present(.teleprompter)
    }

    /// Its view went (the notch closed, Escape): stop with it.
    func ended() {
        guard running else { return }
        running = false
        paused = false
        clock?.invalidate()
        clock = nil
        stopListening()
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
    }

    func stop() {
        running = false
        paused = false
        clock?.invalidate()
        clock = nil
        stopListening()
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        NotchPresenter.shared.dismissOverlay(close: true)
    }

    func togglePause() {
        guard running else { return }
        paused.toggle()
        lastTick = Date()
        if followsVoice { paused ? stopListening() : startListening() }
    }

    func restart() {
        position = 0
        voiceTarget = 0
        paused = false
    }

    /// Moves by whole lines' worth of words (a scroll or the arrow keys).
    func nudge(words delta: Double) {
        position = max(0, min(Double(words.count), position + delta))
        voiceTarget = position
    }

    func faster() { wordsPerMinute = min(Self.paces.upperBound, wordsPerMinute + 10) }
    func slower() { wordsPerMinute = max(Self.paces.lowerBound, wordsPerMinute - 10) }
    func larger() { textSize = min(Self.sizes.upperBound, textSize + 2) }
    func smaller() { textSize = max(Self.sizes.lowerBound, textSize - 2) }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        guard running, !paused else { return }
        if followsVoice {
            // Eases toward the spoken word, so it glides instead of jumping.
            // Snaps the last bit: an ease alone never quite arrives, and the highlight (which rounds
            // down) would sit a word behind.
            position += (voiceTarget - position) * min(1, dt * 8)
            if abs(voiceTarget - position) < 0.05 { position = voiceTarget }
        } else {
            position += wordsPerMinute / 60 * dt
        }
        if position >= Double(words.count) {
            position = Double(words.count)
            if !followsVoice { paused = true }
        }
    }

    // MARK: - Following your voice

    private func restartListening() {
        stopListening()
        if followsVoice, !paused { startListening() }
    }

    private func startListening() {
        guard #available(macOS 26, *), speech == nil else { return }
        listening = true
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                listening = false
                ActivityCenter.shared.show(.notice(title: "Following your voice needs the microphone", detail: "Allow it in Settings → Permissions",
                                                   icon: "mic.slash.fill", tone: .warning), for: 3)
                return
            }
            do {
                let stream = try await SpeechStream.make { text, _, _ in
                    Task { @MainActor in Teleprompter.shared.heard(text) }
                }
                guard listening else { await stream.finish(); return }
                speech = stream
                mic = MicSource { stream.append($0) }
            } catch {
                listening = false
            }
        }
    }

    private func stopListening() {
        listening = false
        mic?.invalidate()
        mic = nil
        if #available(macOS 26, *), let stream = speech as? SpeechStream { Task { await stream.finish() } }
        speech = nil
    }

    /// Finds where the last few spoken words are in the script, a little ahead of where it is,
    /// and moves there. Never back (a misheard word mustn't rewind you), never far ahead.
    private func heard(_ said: String) {
        let spoken = Self.split(said).suffix(3).map(Self.normalized).filter { !$0.isEmpty }
        guard let last = spoken.last else { return }
        let from = Int(voiceTarget)
        let window = min(words.count, from + 14)
        guard from < window else { return }
        var best: Int?
        for i in from..<window where Self.normalized(words[i]) == last {
            // Prefer a match whose words before it also agree.
            let agree = zip(spoken.dropLast().reversed(), stride(from: i - 1, through: max(0, i - 2), by: -1))
                .filter { Self.normalized(words[$0.1]) == $0.0 }.count
            if best == nil || agree > 0 { best = i }
            if agree > 0 { break }
        }
        if let best { voiceTarget = Double(best + 1) }
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Scripts from files

    /// A script from a text, Word, RTF or PDF file.
    func importScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .rtf, .pdf, .init(filenameExtension: "docx")!, .init(filenameExtension: "md")!].compactMap { $0 }
        panel.prompt = "Use Script"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let text = Self.text(of: url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            script = text
        } else {
            ActivityCenter.shared.show(.notice(title: "No text in that file", detail: url.lastPathComponent, icon: "doc.text", tone: .warning), for: 3)
        }
    }

    static func text(of url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" { return PDFDocument(url: url)?.string }
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) { return attributed.string }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
