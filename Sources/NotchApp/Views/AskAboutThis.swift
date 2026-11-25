import AppKit
import SwiftUI

/// "Ask about this" on a selection: a question about the text you picked, answered with what's
/// around it in mind (the app, the window, the page's address and the text near the selection).
/// Ask it something and it answers; tell it how to change the text and it writes the new version,
/// ready to put back in place of the selection.
@MainActor
final class AskSession: ObservableObject {
    let text: String
    let source: SelectionText.Source

    /// The pill has opened into the Ask card.
    @Published var open = false
    @Published var question = ""
    /// The question the answer is for.
    @Published private(set) var asked: String?
    @Published private(set) var answer = ""
    /// The answer is new text for the selection, not words about it.
    @Published private(set) var replaces = false
    @Published private(set) var running = false
    @Published private(set) var error: String?

    private var task: Task<Void, Never>?
    /// What's around the selection, read once, off the main thread, as soon as the card opens.
    private var context: Task<AXReader.Result?, Never>

    init(text: String, source: SelectionText.Source) {
        self.text = text
        self.source = source
        let pid = source.pid
        context = Task.detached(priority: .userInitiated) { AXReader.read(pid: pid) }
    }

    var done: Bool { asked != nil && !running && error == nil && !answer.isEmpty }

    func ask(_ request: String? = nil) {
        let q = (request ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        task?.cancel()
        question = ""
        asked = q
        answer = ""
        replaces = false
        error = nil
        guard AssistantStore.shared.aiAvailable else {
            error = AssistantStore.needsModel
            return
        }
        running = true
        let selection = text
        let appName = source.appName
        let context = context
        task = Task {
            let around = await context.value
            let user = Self.prompt(question: q, selection: selection, appName: appName, around: around)
            do {
                let result = try await OllamaClient.chatStream(system: Self.system, user: user) { soFar in
                    await MainActor.run { [weak self] in self?.show(soFar) }
                }
                try Task.checkCancellation()
                show(result)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }

    func stop() {
        task?.cancel()
        running = false
    }

    /// The model says which kind of reply it's giving on its first line; that line isn't shown.
    private func show(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if "REPLACE".hasPrefix(trimmed) && trimmed.count < 7 { answer = ""; return } // still arriving
        if trimmed.hasPrefix("REPLACE") {
            replaces = true
            answer = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            answer = trimmed
        }
    }

    /// Puts the answer where the selection was: the pill goes first so the paste lands in the app.
    func replace() {
        guard !answer.isEmpty else { return }
        let text = answer, source = source
        SelectionPill.shared.hide()
        NSRunningApplication(processIdentifier: source.pid)?.activate()
        SelectionText.replace(with: text, in: source, after: 0.2)
        ActivityCenter.shared.show(.notice(title: "Replaced", detail: "In \(source.appName ?? "the app") · ⌘Z to undo",
                                           icon: "sparkles", tone: .success), for: 3)
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        Haptics.tap()
    }

    /// Carries on in the chat window, the selection quoted in the first message.
    func continueInChat() {
        guard let asked else { return }
        let quote = text.count > 600 ? String(text.prefix(600)) + "…" : text
        ChatStore.shared.start(question: "\(asked)\n\n> " + quote.replacingOccurrences(of: "\n", with: "\n> "), title: asked, answer: answer)
        SelectionPill.shared.hide()
        ChatWindow.shared.show()
    }

    private static let system = """
    You help with text the user selected in another app. You're given where it is (the app, the window, the address) \
    and some of the text around it, then the selection and the user's request.
    - If the request asks you to change the selected text (rewrite, fix, shorten, expand, translate, reformat, \
    continue, turn it into something else), reply with the line REPLACE, then only the new text, ready to drop in place \
    of the selection: no preamble, no quotes, no notes, the same formatting as the original.
    - Otherwise answer the question about the selection: short and direct, plain text, code in ``` blocks. Use the \
    surrounding text to understand it, and say so if the answer isn't in what you were given.
    """

    nonisolated private static func prompt(question: String, selection: String, appName: String?, around: AXReader.Result?) -> String {
        var lines: [String] = []
        if let appName { lines.append("App: \(appName)") }
        if let title = around?.title, !title.isEmpty { lines.append("Window: \(title)") }
        if let location = around?.location { lines.append("Address: \(location)") }
        if let excerpt = excerpt(around?.text ?? "", near: selection) {
            lines.append("\nText around the selection:\n<<<\n\(excerpt)\n>>>")
        }
        lines.append("\nSelected text:\n<<<\n\(selection.prefix(8_000))\n>>>")
        lines.append("\nRequest: \(question)")
        return lines.joined(separator: "\n")
    }

    /// Up to a few thousand characters of the window's text, centred on the selection when it can
    /// be found there; nothing when the selection is all there is.
    nonisolated private static func excerpt(_ text: String, near selection: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > selection.count + 40 else { return nil }
        let radius = 3_000
        let probe = String(selection.prefix(120))
        guard let range = text.range(of: probe) else { return String(text.prefix(radius * 2)) }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius + selection.count, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }
}

/// The pill opened into a card: what you selected, a field to ask in (with a few common asks to
/// start from), and the answer streaming in under it with what to do with it.
struct AskCard: View {
    @ObservedObject var ask: AskSession
    @ObservedObject var pointer: PillPointer
    let done: () -> Void
    @FocusState private var focused: Bool

    private static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)
    private static let suggestions: [(String, String)] = [
        ("Explain", "Explain this"), ("Summarize", "Summarize this"),
        ("Fix", "Fix the spelling and grammar"), ("Shorter", "Make it shorter"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            quote
            field
            if ask.asked == nil {
                chips
            } else {
                result
            }
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .foregroundStyle(.white)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    /// What it's about: the start of the selection, and where it's from.
    private var quote: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Self.blue.opacity(0.8)).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(ask.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                if let app = ask.source.appName {
                    Text("Selected in \(app)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            Spacer(minLength: 0)
            Button(action: done) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20) }
                .buttonStyle(PillHoverStyle(pointer: pointer, shape: AnyShape(Circle())))
                .foregroundStyle(.white.opacity(0.5))
                .help("Close (Esc)")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var field: some View {
        // A capsule: a continuous rounded rectangle with a radius of half its height pinches at the ends.
        let shape = Capsule()
        let canSend = !ask.question.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(.purple.opacity(0.9))
            TextField(ask.asked == nil ? "Ask about this, or say how to change it" : "Ask a follow-up", text: $ask.question)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit { ask.ask() }
            if ask.running {
                Button { ask.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 8, weight: .bold))
                        .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button { ask.ask() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(canSend ? 1 : 0.4))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(canSend ? Self.blue : .white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Ask (↩)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .clipShape(shape)
        .background(shape.fill(.white.opacity(0.07)))
        .overlay(shape.strokeBorder(.white.opacity(focused ? 0.2 : 0.1), lineWidth: 1))
    }

    private var chips: some View {
        HStack(spacing: 5) {
            ForEach(Self.suggestions, id: \.0) { title, request in
                Button { ask.ask(request) } label: {
                    Text(title).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(.white.opacity(0.07)))
                }
                .buttonStyle(PillHoverStyle(pointer: pointer))
            }
        }
    }

    @ViewBuilder private var result: some View {
        if let error = ask.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
        } else if ask.answer.isEmpty {
            HStack(spacing: 8) {
                ThinkingRing(size: 15, speed: 0.9, disc: false)
                Text(ask.asked ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if ask.replaces {
                    Text("NEW TEXT").font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(.white.opacity(0.4))
                }
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        if ask.replaces {
                            Text(ask.answer).font(.system(size: 12.5)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            AnswerText(text: ask.answer, accent: Self.blue, uniform: true)
                        }
                    }
                    .padding(ask.replaces ? 10 : 0)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(ask.replaces ? 0.06 : 0)))
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                if ask.done { actions }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if ask.replaces {
                action("Replace", "text.insert", primary: true) { ask.replace() }
            }
            action("Copy", "doc.on.doc") { ask.copy() }
            if !ask.replaces {
                action("Replace selection", "text.insert") { ask.replace() }
            }
            Spacer(minLength: 0)
            action("Chat", "bubble.left.and.bubble.right") { ask.continueInChat() }
                .help("Carry on in the chat window")
        }
    }

    private func action(_ title: String, _ icon: String, primary: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(primary ? 1 : 0.8))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(primary ? Self.blue : .white.opacity(0.08)))
        }
        .buttonStyle(PillHoverStyle(pointer: pointer))
    }
}

/// The pill's hover, for the card's buttons too: lit from AppKit's view of the pointer.
struct PillHoverStyle: ButtonStyle {
    @ObservedObject var pointer: PillPointer
    var shape: AnyShape = AnyShape(Capsule())

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                GeometryReader { g in
                    let over = pointer.location.map { g.frame(in: .named(PillPointer.space)).contains($0) } ?? false
                    shape.fill(Color.white.opacity(configuration.isPressed ? 0.18 : over ? 0.1 : 0))
                        .animation(.easeOut(duration: 0.1), value: over)
                }
                .allowsHitTesting(false)
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
