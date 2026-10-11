import AppKit
import SwiftUI

/// Ramble: a big box in the notch to talk (or type, or paste) everything on your mind into, then
/// turn into tasks, events and a note in one go. Dictation apps like FluidVoice type into it while
/// you hold their key; the Dictate button presses that key for you. The draft is kept until it's
/// turned into something.
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
        if AppSettings.shared.rambleAutoDictate, Dictation.app != nil {
            // Once the box has the keyboard, so the words land in it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self.active, !self.dictating { self.toggleDictation() } }
        }
    }

    func close() {
        if dictating { toggleDictation() }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { active = false }
    }

    func toggleDictation() {
        guard Dictation.press() else { return }
        dictating.toggle()
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

/// The dictation app the user has (FluidVoice), and pressing its start/stop key for them.
@MainActor
enum Dictation {
    struct App {
        let name: String
        let keyCode: CGKeyCode
        let modifiers: CGEventFlags
        /// The key, as the user knows it ("fn").
        let keyLabel: String
    }

    /// FluidVoice, with the shortcut set in it (read from its settings each time, so changes there count).
    static var app: App? {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.FluidApp.app") != nil,
              let defaults = UserDefaults(suiteName: "com.FluidApp.app"),
              let raw = defaults.data(forKey: "HotkeyShortcutKey") ?? (defaults.string(forKey: "HotkeyShortcutKey")?.data(using: .utf8)),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let code = obj["keyCode"] as? Int else { return nil }
        let flags = CGEventFlags(rawValue: UInt64(obj["modifierFlagsRawValue"] as? Int ?? 0))
        let label = code == 63 ? "fn" : code == 61 ? "right ⌥" : code == 54 ? "right ⌘" : "its shortcut"
        return App(name: "FluidVoice", keyCode: CGKeyCode(code), modifiers: flags, keyLabel: label)
    }

    /// Presses and releases the dictation key (a modifier key alone, like fn, as the modifier it is).
    @discardableResult
    static func press() -> Bool {
        guard let app else { return false }
        let modifierKeys: [CGKeyCode: CGEventFlags] = [63: .maskSecondaryFn, 61: .maskAlternate, 58: .maskAlternate,
                                                        54: .maskCommand, 55: .maskCommand, 62: .maskControl, 59: .maskControl]
        if let flag = modifierKeys[app.keyCode] {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: app.keyCode, keyDown: down)
                e?.type = .flagsChanged
                e?.flags = down ? flag : []
                e?.post(tap: .cghidEventTap)
            }
        } else {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: app.keyCode, keyDown: down)
                e?.flags = app.modifiers
                e?.post(tap: .cghidEventTap)
            }
        }
        return true
    }
}
