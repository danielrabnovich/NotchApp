import AVFoundation
import AppKit
import SwiftUI

/// Ramble: a big box in the notch to talk (or type, or paste) everything on your mind into, then
/// turn into tasks, events and a note in one go. Dictate turns speech into text on this Mac (the
/// same transcriber as live captions, macOS 26+); any dictation app can type into the box too.
/// The draft is kept until it's turned into something.
@MainActor
final class RambleStore: ObservableObject {
    static let shared = RambleStore()

    @Published var active = false {
        // The notch sizes itself from this: it's taller while rambling.
        didSet { if active != oldValue { NotchPresenter.shared.primary?.objectWillChange.send() } }
    }
    @Published var text: String {
        didSet { UserDefaults.standard.set(text, forKey: "rambleDraft") }
    }
    @Published private(set) var dictating = false
    /// What's being said right now, before it firms up into the text.
    @Published private(set) var hearing = ""
    private var speech: AnyObject?
    private var mic: MicSource?

    /// Dictation built in: the on-device transcriber is there (macOS 26+).
    static var canDictate: Bool { LiveCaptions.isSupported }

    private init() {
        text = UserDefaults.standard.string(forKey: "rambleDraft") ?? ""
    }

    var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }

    func open(_ given: NotchViewModel? = nil) {
        let vm = given ?? NotchPresenter.shared.primary
        AssistantStore.shared.clear()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { active = true }
        vm?.overlay = nil
        vm?.mirror = false
        vm?.open(tab: .ask, reason: .keyboard)
        if AppSettings.shared.rambleAutoDictate, Self.canDictate {
            // Once the box has the keyboard, so the words land in it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self.active, !self.dictating { self.toggleDictation() } }
        }
    }

    func close() {
        if dictating { toggleDictation() }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { active = false }
    }

    func toggleDictation() {
        dictating ? stopDictation() : startDictation()
    }

    private func startDictation() {
        guard #available(macOS 26, *) else { return }
        dictating = true
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                dictating = false
                ActivityCenter.shared.show(.notice(title: "Dictation needs the microphone", detail: "Allow it for NotchApp in Settings → Permissions",
                                                   icon: "mic.slash.fill", tone: .warning), for: 3)
                return
            }
            do {
                let stream = try await SpeechStream.make { text, final in
                    Task { @MainActor in RambleStore.shared.heard(text, final: final) }
                }
                guard dictating else { await stream.finish(); return }
                speech = stream
                mic = MicSource { stream.append($0) }
            } catch {
                dictating = false
                ActivityCenter.shared.show(.notice(title: "Couldn't start dictation", detail: error.localizedDescription,
                                                   icon: "mic.slash.fill", tone: .warning), for: 3)
            }
        }
    }

    private func stopDictation() {
        dictating = false
        mic?.invalidate()
        mic = nil
        if #available(macOS 26, *), let stream = speech as? SpeechStream { Task { await stream.finish() } }
        speech = nil
        // Whatever was still being said goes in as it stands.
        if !hearing.isEmpty { heard(hearing, final: true) }
    }

    private func heard(_ said: String, final: Bool) {
        guard final else { hearing = said; return }
        hearing = ""
        guard !said.isEmpty else { return }
        let joiner = text.isEmpty || text.hasSuffix("\n") || text.hasSuffix(" ") ? "" : " "
        text += joiner + said
    }

    /// Everything said, as tasks (with due dates), events and a note, shown for review first.
    func turnIntoTasks() {
        let dump = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dump.isEmpty else { return }
        if dictating { toggleDictation() }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { active = false }
        let request = """
        Turn this brain dump into actions: a task for each thing to do (with its due date or time when one \
        is said), a calendar event for anything at a set time with others, and one note with the ideas and \
        thoughts that aren't tasks. Keep the user's wording, short.

        \(dump)
        """
        AssistantStore.shared.run(request, route: .actions, action: ("Ramble", "waveform"))
    }

    /// Kept as it is, in Notes, under today's date.
    func saveAsNote() {
        let dump = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dump.isEmpty else { return }
        let store = ScratchpadStore.shared
        let header = "Ramble · " + Date().formatted(date: .abbreviated, time: .shortened)
        store.text += (store.text.isEmpty ? "" : store.text.hasSuffix("\n") ? "\n" : "\n\n") + header + "\n" + dump + "\n"
        text = ""
        close()
        CommandCenter.shared.show(.tasks, pane: TasksPane.notes.rawValue)
    }

    /// The plan from a ramble was added: the draft has done its job.
    func planApplied() { text = "" }
}
