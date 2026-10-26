import AppKit
import SwiftUI

/// A Search answer opened as a chat (see `ChatStore`): a small glass window under the notch that
/// stays up while you work, to keep asking about the answer. Esc or ⌘W closes it.
@MainActor
final class ChatWindow {
    static let shared = ChatWindow()

    private var panel: ChatPanel?

    var isOpen: Bool { panel?.isVisible ?? false }

    /// Carries a Search answer on as a chat and shows it; the notch closes so the window has the keys.
    func open(from job: AssistantStore.Job) {
        ChatStore.shared.start(from: job)
        NotchPresenter.shared.primary?.close()
        show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { place(panel) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// The chat shortcut: a fresh conversation to type into, or, with the window in front, away.
    func toggleNewChat() {
        if let panel, panel.isVisible, panel.isKeyWindow { return close() }
        ChatStore.shared.newChat()
        NotchPresenter.shared.primary?.close()
        show()
    }

    func close() {
        ChatStore.shared.stop()
        panel?.orderOut(nil)
    }

    private func makePanel() -> ChatPanel {
        let panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 540))
        let host = NSHostingView(rootView: ChatView()
            .environmentObject(ChatStore.shared)
            .notchEnvironment())
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// Centred under the notch, on the screen that has it, starting below the furthest the open
    /// notch reaches (Search with results), so opening it again never covers the chat. Shorter if
    /// the screen needs it.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let notch = NotchPresenter.shared.primary?.maxOpenSize.height ?? 300
        let top = min(area.maxY, screen.frame.maxY - notch - 12)
        var frame = panel.frame
        frame.size.height = max(panel.contentMinSize.height, min(540, top - area.minY - 12))
        frame.origin = NSPoint(x: area.midX - frame.width / 2, y: top - frame.height)
        panel.setFrame(frame, display: false)
    }
}

/// Borderless, so the glass is the whole window; still takes the keyboard, moves by its background
/// and resizes from its edges.
private final class ChatPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: 360, height: 320)
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        ChatWindow.shared.close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "w" {
            ChatWindow.shared.close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// iMessage's blue, for what you sent and the send button.
private let messageBlue = Color(red: 0.04, green: 0.52, blue: 1.0)

private struct ChatView: View {
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var settings: AppSettings
    @State private var draft = ""
    @FocusState private var focused: Bool

    // One geometry, so the corners nest: the send button sits `inset` inside the field, and the
    // field `gutter` inside the window, each corner's radius the inner one's plus the gap.
    private let button: CGFloat = 26
    private let inset: CGFloat = 4
    private let gutter: CGFloat = 10
    private var fieldRadius: CGFloat { button / 2 + inset }
    private var radius: CGFloat { fieldRadius + gutter }

    var body: some View {
        VStack(spacing: 0) {
            header
            if chat.messages.isEmpty { empty } else { messages }
            input
        }
        .background(TrayGlass(look: DynamicGlass.Look(settings.glassLevel), glass: settings.usesGlass, radius: radius, minShade: 0.93))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
        // A new or reopened conversation: the keys go straight to the field.
        .onChange(of: chat.title) { _, _ in focused = true }
    }

    /// The buttons line up with the field's edges below; the title is centred on the window,
    /// whatever the buttons on either side add up to.
    private var header: some View {
        HStack(spacing: 2) {
            historyMenu
            Spacer(minLength: 0)
            Button { chat.newChat(); focused = true } label: { Image(systemName: "square.and.pencil").font(.system(size: 11, weight: .medium)) }
                .buttonStyle(NotchIconButtonStyle(size: button))
                .help("New chat")
                .disabled(chat.messages.isEmpty)
            Button { ChatWindow.shared.close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(NotchIconButtonStyle(size: button))
                .help("Close (Esc)")
        }
        .overlay {
            Text(chat.title.isEmpty ? "New Chat" : chat.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(chat.title.isEmpty ? 0.5 : 0.85))
                .lineLimit(1)
                .padding(.horizontal, button * 2 + 8)
                .allowsHitTesting(false)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, gutter)
        .padding(.top, gutter)
        .padding(.bottom, 6)
    }

    /// Earlier conversations, newest first.
    private var historyMenu: some View {
        Menu {
            if chat.history.isEmpty {
                Text("No earlier chats")
            } else {
                ForEach(chat.history.prefix(30)) { saved in
                    Button {
                        chat.open(saved)
                    } label: {
                        Text(saved.title.isEmpty ? "Untitled" : saved.title)
                        Text(saved.updated.formatted(.relative(presentation: .named)))
                    }
                }
                Divider()
                Button("Copy This Chat", action: copyAll).disabled(chat.messages.isEmpty)
                Button("Clear History", role: .destructive) { chat.clearHistory() }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .medium))
        }
        // A button-style menu, so it sits and lights up exactly like the buttons opposite.
        .menuStyle(.button)
        .buttonStyle(NotchIconButtonStyle(size: button))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Earlier chats")
    }

    private var empty: some View {
        ChatWelcome { example in
            draft = example
            focused = true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.messages) { message in
                        MessageRow(message: message, isLast: message.id == chat.messages.last?.id)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                // Your messages end where the send button does.
                .padding(.horizontal, gutter + inset)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .onChange(of: chat.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Messages' field: a rounded box with the round blue send button inside it, at the bottom
    /// right. One line tall, the button sits centred, the same gap above, below and beside it.
    private var input: some View {
        let shape = RoundedRectangle(cornerRadius: fieldRadius, style: .circular)
        return HStack(alignment: .bottom, spacing: 6) {
            TextField(chat.messages.isEmpty ? "Ask anything" : "Ask a follow-up, or add context", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                // At least the button's height, its one line centred in it.
                .frame(minHeight: button, alignment: .leading)
            Group {
                if chat.isRunning {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: button, height: button)
                            .background(Circle().fill(.white.opacity(0.25)))
                    }
                    .help("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(canSend ? 1 : 0.45))
                            .frame(width: button, height: button)
                            .background(Circle().fill(canSend ? messageBlue : .white.opacity(0.12)))
                    }
                    .disabled(!canSend)
                    .animation(.easeOut(duration: 0.12), value: canSend)
                    .help("Send (↩) · ⌥↩ for a new line")
                }
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
        }
        .padding(.leading, 12)
        .padding([.trailing, .vertical], inset)
        .background(shape.fill(.white.opacity(0.07)))
        .overlay(shape.strokeBorder(.white.opacity(focused ? 0.18 : 0.1), lineWidth: 1))
        .padding([.horizontal, .bottom], gutter)
        .padding(.top, 6)
    }

    private func send() {
        guard !chat.isRunning, canSend else { return }
        chat.send(draft)
        draft = ""
    }

    private func copyAll() {
        let text = chat.messages.map { ($0.role == .user ? "> " : "") + $0.text }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Haptics.tap()
    }
}

private struct MessageRow: View {
    let message: ChatStore.Message
    let isLast: Bool
    @EnvironmentObject private var chat: ChatStore

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(messageBlue))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let route = message.job?.route, message.job?.ranTitle == nil { origin(route) }
                switch message.state {
                case .running(let stage) where message.text.isEmpty:
                    HStack(spacing: 8) {
                        ThinkingRing(size: 16, speed: 0.9, disc: false)
                        Text(stage)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.vertical, 4)
                case .failed(let error) where message.text.isEmpty:
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                default:
                    if let job = message.job, ChatResult.shows(job) {
                        ChatResult(job: job, messageID: message.id)
                    } else {
                        AnswerText(text: message.text, accent: messageBlue, uniform: true)
                    }
                }
                if !message.sources.isEmpty { sources }
                if isLast, !message.isRunning, !message.text.isEmpty { actions }
            }
            // Words keep clear of the right edge, as Messages' do; a result's card uses the width.
            .padding(.trailing, message.job.map(ChatResult.shows) == true ? 0 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Where a reply came from, in that route's colour.
    private func origin(_ route: AssistantStore.Route) -> some View {
        let (icon, text): (String, String) = switch route {
        case .web: ("globe", "Searched the web")
        case .files: ("doc.text.magnifyingglass", "Searched your Mac")
        case .weather: ("cloud.sun", "Forecast")
        case .calendar: ("calendar", "Your calendar")
        case .notes: ("note.text", "Your notes and tasks")
        case .screen: ("macwindow", "Looked at your screen")
        case .recall: ("clock.arrow.circlepath", "Recall")
        case .help: ("questionmark.circle", "NotchApp help")
        case .actions: ("sparkles", "Actions")
        case .write: ("character.bubble", "Written for you")
        case .app: ("wand.and.stars", "In the app in front")
        }
        return Label(text, systemImage: icon)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(route.tint)
            .labelStyle(.titleAndIcon)
    }

    private var sources: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(message.sources.prefix(6).enumerated()), id: \.element.id) { i, source in
                    Button { NSWorkspace.shared.open(source.url) } label: {
                        HStack(spacing: 5) {
                            Favicon(host: source.host, size: 12) {
                                Text("\(i + 1)").font(.system(size: 8.5, weight: .bold).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                            }
                            Text(source.host).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(source.title + "\n" + source.url.absoluteString)
                }
            }
        }
    }

    /// Under the newest reply: small icons, as Messages keeps its own out of the way.
    private var actions: some View {
        HStack(spacing: 2) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                Haptics.tap()
            } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                .help("Copy")
            Button { chat.retry() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)) }
                .help("Try again")
        }
        .buttonStyle(NotchIconButtonStyle(size: 22))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.leading, -5)
    }
}

/// An empty chat: what it can do, one thing at a time. The symbol morphs from one to the next
/// and the line under it rolls over; clicking the example puts it in the field to send or edit.
private struct ChatWelcome: View {
    let tryExample: (String) -> Void

    private struct Ability {
        let icon: String
        let title: String
        let example: String
        let tint: Color
    }

    private static let abilities: [Ability] = [
        Ability(icon: "magnifyingglass", title: "Search the web, with sources", example: "What's new in the latest macOS?", tint: messageBlue),
        Ability(icon: "clock.arrow.circlepath", title: "Find what you saw before, with Recall", example: "What was that error in Terminal yesterday?", tint: .indigo),
        Ability(icon: "doc.text.magnifyingglass", title: "Find your files", example: "Find the invoice PDF from March", tint: .cyan),
        Ability(icon: "calendar", title: "Check your calendar", example: "What's on tomorrow afternoon?", tint: .red),
        Ability(icon: "cloud.sun", title: "Get the forecast", example: "Will it rain this weekend?", tint: .yellow),
        Ability(icon: "pencil.line", title: "Write it, reword it, translate it", example: "Make this friendlier: “Send me the file.”", tint: .orange),
        Ability(icon: "bolt", title: "Get things done", example: "Remind me to call Sam at 5", tint: .green),
        Ability(icon: "arrow.turn.down.right", title: "Carry on from Search", example: "Press ⌘↩ on any Search answer", tint: .purple),
        Ability(icon: "bubble.left.and.text.bubble.right", title: "Pick up an earlier chat", example: "They're under the clock, top left", tint: .teal),
    ]

    @State private var index = 0
    @State private var hovering = false
    private let timer = Timer.publish(every: 2.8, on: .main, in: .common).autoconnect()

    var body: some View {
        let ability = Self.abilities[index]
        // The last two are hints, not prompts to send.
        let sendable = index < Self.abilities.count - 2
        VStack(spacing: 14) {
            Image(systemName: ability.icon)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(ability.tint)
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: 58, height: 44)

            VStack(spacing: 5) {
                Text("Ask anything")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                // A new line each time, rolling up through a fixed slot that clips it.
                ZStack {
                    Text(ability.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .id(index)
                        .transition(Self.roll)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 18)
                .clipped()
            }

            Button { if sendable { tryExample(ability.example) } } label: {
                // The capsule stays and eases to the new width; the words change in place.
                Text(sendable ? "Try “\(ability.example)”" : ability.example)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(hovering && sendable ? 0.85 : 0.5))
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
                    .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Capsule().fill(.white.opacity(hovering && sendable ? 0.12 : 0.06)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(sendable ? "Put this in the field" : "")

            // Where in the cycle it is; a click jumps there.
            HStack(spacing: 5) {
                ForEach(Self.abilities.indices, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(i == index ? 0.7 : 0.18))
                        .frame(width: i == index ? 14 : 5, height: 5)
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture { show(i) }
                }
            }
        }
        .padding(.horizontal, 24)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: index)
        // It holds still while the example is pointed at.
        .onReceive(timer) { _ in if !hovering { show((index + 1) % Self.abilities.count) } }
    }

    private static let roll = AnyTransition.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                         removal: .move(edge: .top).combined(with: .opacity))

    private func show(_ i: Int) { index = i }
}

/// A reply Search found by a route other than writing an answer: shown with Search's own views
/// (files, the forecast, the calendar, notes, Recall, actions to review), each in a card sized
/// for the chat.
private struct ChatResult: View {
    let job: AssistantStore.Job
    let messageID: UUID
    @EnvironmentObject private var chat: ChatStore
    @State private var excluded: Set<UUID> = []
    /// The Recall moment shown large; clicking another in the list shows that one.
    @State private var moment = 0

    /// Whether this job has something to show beyond words.
    static func shows(_ job: AssistantStore.Job) -> Bool {
        if job.ranTitle != nil { return true }
        guard (job.answer ?? "").isEmpty else { return false }
        switch job.route {
        case .files?, .weather?, .calendar?, .notes?, .recall?, .actions?, .app?: return true
        default: return false
        }
    }

    var body: some View {
        if let ran = job.ranTitle {
            Label(ran, systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .symbolRenderingMode(.multicolor)
        } else {
            switch job.route {
            case .files?: files
            case .weather?: if let report = job.weather { card(height: 236) { WeatherCard(report: report, accent: messageBlue, stacked: true) } }
            case .calendar?: if let answer = job.calendar { card(height: 170) { CalendarResult(answer: answer) } }
            case .notes?: if let answer = job.notes { card(height: 170) { NotesResult(answer: answer) } }
            case .recall?: if let answer = job.recall { recall(answer) }
            case .actions?: if let plan = job.plan { card(height: 190) { PlanView(plan: plan, excluded: $excluded, apply: apply, cancel: { chat.markRan(messageID, nil) }) } }
            case .app?: picks
            default: EmptyView()
            }
        }
    }

    private func card<Content: View>(height: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
    }

    @ViewBuilder private var files: some View {
        if job.files.isEmpty {
            Text("No files matched.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
        } else {
            VStack(spacing: 0) {
                ForEach(job.files.prefix(8)) { hit in
                    FileRow(hit: hit) { QuickLookPreview.shared.show([hit.url]) }
                }
                if job.findingMore {
                    HStack(spacing: 6) {
                        ThinkingRing(size: 12, speed: 0.9, disc: false)
                        Text("Finding more").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(.top, 4)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
        }
    }

    /// Recall's own view, which puts its sentence (when a model wrote one) over the moments.
    private func recall(_ answer: RecallAnswer) -> some View {
        card(height: (answer.sentence?.isEmpty == false ? 50 : 0) + (answer.hits.count > 1 ? 268 : 120)) {
            RecallResults(answer: answer, selection: $moment, stacked: true)
        }
    }

    private var picks: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("In \(job.appName ?? "the app"):").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            ForEach(job.appPicks) { pick in
                Button { CommandCenter.shared.run([pick]) } label: {
                    Label(pick.title, systemImage: pick.icon).font(.system(size: 12.5))
                }
                .buttonStyle(NotchPillButtonStyle(height: 24))
            }
        }
    }

    /// The reviewed actions run, and the reply says so.
    private func apply(_ plan: CommandPlanner.Plan) {
        let chosen = plan.commands.filter { !excluded.contains($0.id) }
        guard !chosen.isEmpty else { return }
        CommandCenter.shared.run(chosen)
        chat.markRan(messageID, chosen.map(\.title).joined(separator: ", "))
    }
}
