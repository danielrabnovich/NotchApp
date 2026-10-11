import AppKit
import ApplicationServices
import SwiftUI

/// A saved prompt to run on selected text ("Fix spelling and grammar", "Summarize").
struct AICommand: Codable, Identifiable, Hashable {
    enum Output: String, Codable, CaseIterable {
        /// Put the result in place of the selection, in the app it came from.
        case replace
        /// Show the result in the notch, to copy or act on.
        case show
    }

    var id = UUID()
    var name: String
    var prompt: String
    var icon: String
    var output: Output
}

/// The saved AI Commands, in order. Saved.
@MainActor
final class AICommandStore: ObservableObject {
    static let shared = AICommandStore()

    @Published var commands: [AICommand] {
        didSet { if let data = try? JSONEncoder().encode(commands) { UserDefaults.standard.set(data, forKey: "aiCommands") } }
    }

    private init() {
        let saved = UserDefaults.standard.data(forKey: "aiCommands").flatMap { try? JSONDecoder().decode([AICommand].self, from: $0) }
        commands = saved ?? Self.defaults
    }

    static let defaults: [AICommand] = [
        AICommand(name: "Fix spelling and grammar",
                  prompt: "Fix the spelling, grammar and punctuation. Keep the wording, tone and formatting otherwise exactly as they are.",
                  icon: "checkmark.seal", output: .replace),
        AICommand(name: "Make it friendlier", prompt: "Rewrite this to sound warmer and friendlier, keeping the meaning and roughly the length.",
                  icon: "face.smiling", output: .replace),
        AICommand(name: "Make it shorter", prompt: "Make this shorter and clearer. Keep every point that matters.",
                  icon: "arrow.down.right.and.arrow.up.left", output: .replace),
        AICommand(name: "Make it more professional", prompt: "Rewrite this in a clear, professional tone, keeping the meaning.",
                  icon: "briefcase", output: .replace),
        AICommand(name: "Summarize", prompt: "Summarize this in three short bullet points.", icon: "text.alignleft", output: .show),
        AICommand(name: "Explain", prompt: "Explain this simply, in a few sentences. If it's code or an error, say what it does or what's wrong.",
                  icon: "lightbulb", output: .show),
        AICommand(name: "Translate to English", prompt: "Translate this into English.", icon: "character.bubble", output: .show),
        AICommand(name: "Write a reply", prompt: "Draft a short, friendly reply to this message, ready to send.", icon: "arrowshape.turn.up.left", output: .show),
    ]

    func command(_ id: UUID) -> AICommand? { commands.first { $0.id == id } }

    func add() {
        commands.append(AICommand(name: "New command", prompt: "Describe what to do with the selected text.", icon: "sparkles", output: .show))
    }

    func remove(_ id: UUID) { commands.removeAll { $0.id == id } }
    func resetToDefaults() { commands = Self.defaults }

    /// Commands for what's typed: "ai …" lists them all (filtered by the rest); a name typed on its
    /// own ("fix spe…") offers the closest ones.
    func matches(_ raw: String) -> (commands: [AICommand], explicit: Bool) {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["ai ", "ai:"] where (lower + " ").hasPrefix(prefix) {
            let rest = String((lower + " ").dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return (rest.isEmpty ? commands : commands.filter { $0.name.lowercased().contains(rest) }, true)
        }
        guard lower.count >= 3 else { return ([], false) }
        return (commands.filter { $0.name.lowercased().hasPrefix(lower) || $0.name.lowercased().contains(" " + lower) }, false)
    }
}

/// Selected text in other apps, and putting text back in place of it.
@MainActor
enum SelectionText {
    /// The app the text came from, to paste the result back into.
    struct Source {
        let pid: pid_t
        let appName: String?
    }

    /// The frontmost app's selected text, through Accessibility (no clipboard involved).
    static func read() -> (text: String, source: Source)? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, Source(pid: app.processIdentifier, appName: app.localizedName))
    }

    /// Pastes `text` over the selection in the source app (which keeps its selection while the
    /// notch is up, since the notch never takes over as the active app). The clipboard is put
    /// back afterwards.
    static func replace(with text: String, in source: Source, after delay: TimeInterval = 0.55) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let app = NSRunningApplication(processIdentifier: source.pid) else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != source.pid { app.activate() }
            let pasteboard = NSPasteboard.general
            let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            } ?? []
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            ClipboardHistory.shared.ignoreCurrent()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                let v = CGKeyCode(9) // kVK_ANSI_V
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: down)
                    e?.flags = .maskCommand
                    e?.post(tap: .cghidEventTap)
                }
                // Give the app a moment to read the clipboard, then put the user's back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    pasteboard.clearContents()
                    if !saved.isEmpty { pasteboard.writeObjects(saved) }
                    ClipboardHistory.shared.ignoreCurrent()
                }
            }
        }
    }
}

/// Runs AI Commands: on the selection captured by "Ask about this", the selection in the app in
/// front, or (for commands that show their result) the clipboard.
@MainActor
enum AICommandRunner {
    static func run(_ command: AICommand) {
        let assistant = AssistantStore.shared
        if let context = assistant.screenContext, context.hasSelection, let selection = context.selection {
            let source = context.pid.map { SelectionText.Source(pid: $0, appName: context.appName) }
            return start(command, text: selection, source: source)
        }
        if let (text, source) = SelectionText.read() {
            return start(command, text: text, source: source)
        }
        if command.output == .show, let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
            return start(command, text: clip, source: nil)
        }
        ActivityCenter.shared.show(.notice(title: "Select some text first", detail: command.name, icon: "text.cursor", tone: .warning), for: 3)
    }

    private static func start(_ command: AICommand, text: String, source: SelectionText.Source?) {
        AssistantStore.shared.write(.command(command, text: text, replaceIn: command.output == .replace ? source : nil))
        let vm = NotchPresenter.shared.primary
        if vm?.isOpen != true { vm?.open(tab: .ask, takeKeyboard: false, reason: .system) }
    }
}
