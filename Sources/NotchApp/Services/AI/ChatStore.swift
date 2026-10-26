import AppKit
import SwiftUI

/// A Search answer carried on as a conversation, in its own small window (`ChatWindow`): ask a
/// follow-up, add what was missing, or have the last reply done again, without starting over.
/// Follow-ups see the whole conversation; the model searches the web again when it needs facts it
/// doesn't have, and a chat that started from the screen keeps looking at that screen.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        enum State: Equatable { case running(String), done, failed(String) }

        let id = UUID()
        let role: Role
        var text: String
        var sources: [WebSource] = []
        var state: State = .done
        /// A reply found the way Search finds things (files, weather, calendar, Recall, actions…),
        /// shown as Search shows it; `text` then says in words what it found.
        var job: AssistantStore.Job?

        var isRunning: Bool { if case .running = state { true } else { false } }
    }

    @Published private(set) var messages: [Message] = []
    /// The first question, for the window's title.
    @Published private(set) var title = ""
    /// Earlier conversations, newest first (kept in Application Support, on this Mac).
    @Published private(set) var history: [Saved] = []
    /// The conversation showing, as it's kept in `history` (nil until it has something to keep).
    private var conversationID: UUID?

    struct Saved: Codable, Identifiable, Equatable {
        struct Line: Codable, Equatable {
            struct Source: Codable, Equatable { let title: String; let url: URL; let snippet: String }
            let user: Bool
            let text: String
            var sources: [Source] = []
        }
        let id: UUID
        var title: String
        var updated: Date
        var lines: [Line]
    }

    private init() {
        if let data = try? Data(contentsOf: Self.historyURL), let saved = try? JSONDecoder().decode([Saved].self, from: data) {
            history = saved
        }
    }

    /// The screen the conversation is about, when it started from one.
    private var screen: ScreenContext?
    private var task: Task<Void, Never>?
    /// Replies stopped mid-search: a search's late updates mustn't set them running again.
    private var stopped: Set<UUID> = []

    var isRunning: Bool { messages.last?.isRunning ?? false }

    /// A finished Search result that a conversation can carry on from (anything but a meeting's notes).
    static func canContinue(_ job: AssistantStore.Job) -> Bool {
        job.state == .done && job.meeting == nil && !ChatStore.Message.words(for: job).isEmpty
    }

    /// Starts a conversation from a Search answer (its question, answer and sources).
    func start(from job: AssistantStore.Job) {
        task?.cancel()
        title = job.actionTitle ?? job.query
        screen = job.route == .screen ? AssistantStore.shared.lastScreen : nil
        conversationID = nil
        var reply = Message(role: .assistant, text: "")
        reply.show(job)
        messages = [Message(role: .user, text: job.actionTitle ?? job.query), reply]
        keep()
    }

    /// An empty conversation, to ask anything.
    func newChat() {
        stop()
        messages = []
        title = ""
        screen = nil
        conversationID = nil
    }

    /// Brings back an earlier conversation, to read or carry on. (The screen it may have been
    /// about isn't kept, so follow-ups go by what was said.)
    func open(_ saved: Saved) {
        stop()
        conversationID = saved.id
        title = saved.title
        screen = nil
        messages = saved.lines.map { line in
            Message(role: line.user ? .user : .assistant, text: line.text,
                    sources: line.sources.map { WebSource(title: $0.title, url: $0.url, snippet: $0.snippet) })
        }
    }

    /// Actions offered in a reply were run (their titles) or cancelled (nil): it says so instead
    /// of offering them again.
    func markRan(_ id: UUID, _ titles: String?) {
        update(id) { message in
            if let titles {
                message.job?.ranTitle = titles
                if let job = message.job { message.text = Message.words(for: job) }
            } else {
                message.job = nil
                message.text = "Cancelled."
            }
        }
        keep()
    }

    func delete(_ saved: Saved) {
        history.removeAll { $0.id == saved.id }
        if conversationID == saved.id { conversationID = nil }
        writeHistory()
    }

    func clearHistory() {
        history = []
        conversationID = nil
        writeHistory()
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        if title.isEmpty { title = text }
        messages.append(Message(role: .user, text: text))
        reply()
    }

    /// The last reply again, written afresh.
    func retry() {
        guard !isRunning, messages.last?.role == .assistant, messages.count >= 2 else { return }
        messages.removeLast()
        reply()
    }

    func stop() {
        task?.cancel()
        task = nil
        guard let last = messages.indices.last, messages[last].isRunning else { return }
        stopped.insert(messages[last].id)
        if messages[last].text.isEmpty { messages[last].state = .failed("Stopped") } else { messages[last].state = .done; keep() }
    }

    // MARK: - History

    private static let historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchApp/Chats.json")
    private static let historyLimit = 100

    /// Puts the conversation as it is now at the top of the history.
    private func keep() {
        let lines = messages.filter { !$0.isRunning && !$0.text.isEmpty }.map { m in
            Saved.Line(user: m.role == .user, text: m.text,
                       sources: m.sources.map { .init(title: $0.title, url: $0.url, snippet: $0.snippet) })
        }
        guard lines.contains(where: { !$0.user }) else { return }
        let id = conversationID ?? UUID()
        conversationID = id
        history.removeAll { $0.id == id }
        history.insert(Saved(id: id, title: title, updated: Date(), lines: lines), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        writeHistory()
    }

    private func writeHistory() {
        let snapshot = history, url = Self.historyURL
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: - Replying

    private func reply() {
        guard let question = messages.last(where: { $0.role == .user })?.text else { return }
        // Everything before the latest question, oldest first.
        let earlier = Array(messages.dropLast())
        messages.append(Message(role: .assistant, text: "", state: .running("Thinking")))
        let id = messages[messages.count - 1].id
        let screen = screen
        task = Task {
            let progress: @Sendable (String) async -> Void = { stage in
                await MainActor.run { ChatStore.shared.update(id) { if $0.isRunning { $0.state = .running(stage) } } }
            }
            let partial: @Sendable (String, [WebSource]) async -> Void = { text, sources in
                await MainActor.run { ChatStore.shared.update(id) { $0.text = text; if !sources.isEmpty { $0.sources = sources } } }
            }
            do {
                if let screen {
                    // About the screen it started from: that window, with what's been asked of it.
                    guard AssistantStore.shared.aiAvailable else { throw OllamaClient.OllamaError(message: AssistantStore.needsModel) }
                    let (text, sources) = try await ScreenQuestion.answer(question, context: screen, history: Self.exchanges(earlier),
                                                                          progress: progress, partial: partial)
                    try Task.checkCancellation()
                    update(id) { $0.text = text; $0.sources = sources; $0.state = .done }
                } else if earlier.isEmpty || !AssistantStore.shared.aiAvailable || Self.isCommand(question) {
                    // The first question is a search, as in the Search tab; so is a command ("timer 25 min"),
                    // which a model answering in words would only claim to have done.
                    await search(question, conversation: nil, into: id)
                } else {
                    let conversation = Self.transcript(earlier)
                    switch try await Self.followUp(question, conversation: conversation, partial: partial) {
                    case .answer(let text):
                        try Task.checkCancellation()
                        update(id) { $0.text = text; $0.state = .done }
                    case .search(let request):
                        DebugHooks.log("Chat: searching '\(request)' for: \(question)")
                        update(id) { $0.text = "" }
                        await search(request, conversation: conversation, into: id)
                    }
                }
                guard !Task.isCancelled else { return }
                keep()
            } catch is CancellationError {
            } catch {
                // A stopped stream ends in URLError.cancelled, not CancellationError: Stop already said what happened.
                guard !Task.isCancelled else { return }
                update(id) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// Runs a request the way the Search tab would, its progress and result going into one reply.
    private func search(_ request: String, conversation: String?, into id: UUID) async {
        let search = AssistantStore.shared.runForChat(request, conversation: conversation) { job in
            guard !ChatStore.shared.stopped.contains(id) else { return }
            ChatStore.shared.update(id) { $0.show(job) }
        }
        await withTaskCancellationHandler { await search.value } onCancel: { search.cancel() }
    }

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
    }

    /// Questions and their answers, for the screen answerer's memory.
    private static func exchanges(_ messages: [Message]) -> [ScreenQuestion.Exchange] {
        stride(from: 0, to: messages.count - 1, by: 2).compactMap { i in
            guard messages[i].role == .user, messages[i + 1].role == .assistant else { return nil }
            return .init(question: messages[i].text, answer: messages[i + 1].text)
        }
    }

    /// The conversation as text for the model, with each answer's sources listed under it.
    private static func transcript(_ messages: [Message]) -> String {
        messages.map { m in
            guard m.role == .assistant else { return "User: \(m.text)" }
            var out = "Assistant: \(Self.uncited(String(m.text.prefix(2000))))"
            if !m.sources.isEmpty {
                // Background for follow-ups, set apart so it isn't copied into the next reply as a list.
                let notes = m.sources.prefix(6).map { "\($0.host): \($0.snippet.prefix(300))" }.joined(separator: " | ")
                out += "\n(Background the assistant read for that answer, not shown to the user: \(notes))"
            }
            return out
        }.joined(separator: "\n\n")
    }

    /// A follow-up that's a command Search runs as it stands. Translating and reworking text are
    /// left to the conversation: in a chat they mean what was just said, not the clipboard.
    private static func isCommand(_ text: String) -> Bool {
        AssistantStore.instantCommands(text).contains { command in
            switch command.action {
            case .translate, .transformClipboard: false
            default: true
            }
        }
    }

    /// Without sources of its own, a reply's [1] markers would point at nothing.
    nonisolated static func uncited(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s?(\[\d+\])+"#, with: "", options: .regularExpression)
    }

    private enum FollowUp { case answer(String), search(String) }

    /// A follow-up: answered from the conversation, or, when it needs anything Search can reach
    /// (the web, files, calendar, notes, weather, Recall, doing something), handed back as a request
    /// that stands on its own, for Search to route.
    private static func followUp(_ question: String, conversation: String,
                                 partial: @escaping @Sendable (String, [WebSource]) async -> Void) async throws -> FollowUp {
        let system = """
        You're carrying on a conversation in NotchApp's search. Today is \(Date().formatted(date: .complete, time: .omitted)).
        Answer the user's latest message in the light of everything before it: they may add context, ask you to reword, \
        shorten, expand or explain, or ask something new. Do exactly what they ask.
        Search can also reach things you can't see: the web (recent events, prices, specifics you aren't sure of), \
        the user's files, calendar, notes and tasks, the weather, Recall (what was on their screen before), and actions \
        (timers, events, reminders, settings). If the message needs any of those, don't guess: reply with ONLY this line:
        SEARCH: <the request rewritten so it stands on its own, e.g. "weather in Paris tomorrow", "find the invoice PDF from March">
        Otherwise answer in plain text: no headings, no bold. Code goes in a ``` block. Never cite [numbers], list sources \
        or repeat the background notes; just answer. Keep it short unless asked for more.
        """
        let user = "Conversation so far:\n\(conversation)\n\nLatest message: \(question)"
        // Held back until it's clear the reply isn't a search request.
        let text = try await OllamaClient.chatStream(system: system, user: user) { soFar in
            let head = soFar.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard head.count >= 7, !head.hasPrefix("SEARCH:") else { return }
            await partial(uncited(soFar), [])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("SEARCH:") else { return .answer(uncited(trimmed)) }
        let request = trimmed.dropFirst("SEARCH:".count).split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return .search(request.isEmpty ? question : request)
    }
}

extension ChatStore.Message {
    /// Takes a Search job's progress and result.
    mutating func show(_ job: AssistantStore.Job) {
        self.job = job
        sources = job.sources
        text = Self.words(for: job)
        switch job.state {
        case .running(let stage): state = .running(stage)
        case .done: state = .done
        case .failed(let error): state = .failed(error)
        }
    }

    /// What a job found, in words: the answer when it wrote one, else a line saying what's shown
    /// (for the history, and for the model to know what was found when asked a follow-up).
    static func words(for job: AssistantStore.Job) -> String {
        if let ran = job.ranTitle { return "Done: \(ran)" }
        if let answer = job.answer, !answer.isEmpty { return answer }
        guard job.state == .done else { return "" }
        switch job.route {
        case .files?:
            return job.files.isEmpty ? "No files matched." : "Found these files: " + job.files.prefix(8).map(\.url.lastPathComponent).joined(separator: ", ")
        case .weather?:
            guard let w = job.weather else { return "" }
            let day = w.days.indices.contains(w.focusDay) ? w.days[w.focusDay] : nil
            return "Weather in \(w.place): now \(Int(w.currentTemp.rounded()))°\(w.unit), feels like \(Int(w.feelsLike.rounded()))°"
                + (day.map { ". \($0.date.formatted(.dateTime.weekday(.wide).month().day())): high \(Int($0.high.rounded()))°, low \(Int($0.low.rounded()))°, \($0.rainChance)% chance of rain" } ?? "")
        case .calendar?:
            guard let c = job.calendar else { return "" }
            return ([c.headline, c.detail].compactMap { $0 } + c.events.prefix(8).map { "• \($0.start.formatted(date: .abbreviated, time: .omitted)) \($0.timeText): \($0.title)" }).joined(separator: "\n")
        case .notes?:
            guard let n = job.notes else { return "" }
            return ([n.headline, n.detail].compactMap { $0 } + n.lines.prefix(8).map { "• \($0.text)" }).joined(separator: "\n")
        case .recall?:
            guard let r = job.recall else { return "" }
            if let sentence = r.sentence, !sentence.isEmpty { return sentence }
            return r.hits.isEmpty ? "Nothing in Recall matched." : "Found in Recall: " + r.hits.prefix(5).map { [$0.appName, $0.title].compactMap { $0 }.joined(separator: " – ") }.joined(separator: "; ")
        case .actions?:
            return "Proposed: " + (job.plan?.commands.map(\.title).joined(separator: ", ") ?? "")
        case .app?:
            return "In \(job.appName ?? "the app"): " + job.appPicks.map(\.title).joined(separator: ", ")
        default:
            return job.sources.isEmpty ? "" : "Results: " + job.sources.prefix(6).map(\.title).joined(separator: "; ")
        }
    }
}
