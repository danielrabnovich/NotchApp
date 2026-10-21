import AppKit
import SwiftUI

/// The Ask tab's search: one query at a time, routed automatically to the user's files or the web.
/// It keeps running in the background if the notch closes and announces itself when done.
@MainActor
final class AssistantStore: ObservableObject {
    static let shared = AssistantStore()

    enum Route: String { case files, web, weather, actions, calendar, notes, screen, write, app, help, recall }

    /// Text work for the model from the command bar.
    enum Writing {
        case translate(String, to: String)
        /// An AI Command on some text; with a source app, the result replaces the selection there.
        case command(AICommand, text: String, replaceIn: SelectionText.Source?)

        var query: String {
            switch self {
            case let .translate(text, target): "Translate to \(target): \(text.prefix(60))"
            case let .command(command, text, _): "\(command.name): \(text.prefix(60))"
            }
        }

        var system: String {
            switch self {
            case let .translate(_, target):
                return "Translate the user's text into \(target). Reply with only the translation: keep the meaning, tone and formatting; no notes, no quotes."
            case let .command(command, _, replace):
                let only = replace != nil
                    ? "Reply with only the new text, ready to drop in place of the original: no preamble, no quotes, no notes, no markdown unless the original had it."
                    : "Reply with only the result: no preamble. Plain text; code in a ``` block."
                return "You apply an instruction to the user's text.\nInstruction: \(command.prompt)\n\(only)"
            }
        }

        var text: String {
            switch self {
            case let .translate(text, _): text
            case let .command(_, text, _): text
            }
        }

        var title: String {
            switch self {
            case let .translate(_, target): "Translate to \(target)"
            case let .command(command, _, _): command.name
            }
        }

        var icon: String {
            switch self {
            case .translate: "character.bubble"
            case let .command(command, _, _): command.icon
            }
        }
    }

    /// Runs a writing task (translate…) as a job, streaming the result into the answer view.
    private var lastWriting: Writing?

    func write(_ writing: Writing) {
        lastWriting = writing
        let source = writing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        task?.cancel()
        var job = Job(query: writing.query, route: .write)
        job.actionTitle = writing.title
        job.actionIcon = writing.icon
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { current = job }
        let id = job.id
        task = Task {
            guard aiAvailable else {
                update(id) { $0.state = .failed("This needs an AI model: start Ollama, or add a cloud model's key, in Settings → Search.") }
                return
            }
            update(id) { $0.state = .running(stage: "Writing") }
            do {
                let result = try await OllamaClient.chatStream(system: writing.system, user: String(source.prefix(12_000))) { soFar in
                    await MainActor.run { AssistantStore.shared.update(id, animated: false) { $0.answer = soFar } }
                }
                try Task.checkCancellation()
                update(id) { $0.answer = result; $0.state = .done }
                // A replace command: put the result where the selection was, and get out of the way.
                if case let .command(command, _, source?) = writing, !result.isEmpty {
                    NotchPresenter.shared.primary?.close()
                    SelectionText.replace(with: result, in: source)
                    ActivityCenter.shared.show(.notice(title: command.name, detail: "Replaced in \(source.appName ?? "the app") · ⌘Z to undo",
                                                       icon: command.icon, tone: .success), for: 3)
                    // It's done its job where the text was: the next open starts fresh.
                    if current?.id == id { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { current = nil } }
                }
            } catch is CancellationError {
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// What the follow-up button under the current answer does.
    private var followUp: (() -> Void)?

    /// Writing done by the model on material it's given (a meeting's notes, catching up on a call),
    /// shown like any answer. `followUp`, once it's done, puts a button under it.
    func runCustom(query: String, title: String, icon: String, stage: String = "Writing", meeting: UUID? = nil,
                   work: @escaping @Sendable (@escaping @Sendable (String) async -> Void) async throws -> String,
                   followUp: (@MainActor (String) -> (title: String, run: () -> Void)?)? = nil) {
        task?.cancel()
        var job = Job(query: query, route: .write)
        job.actionTitle = title
        job.actionIcon = icon
        job.meeting = meeting
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { current = job }
        self.followUp = nil
        let id = job.id
        task = Task {
            // A meeting's transcript and sound are there without a model; its notes say what's missing.
            guard aiAvailable || meeting != nil else {
                update(id) { $0.state = .failed(Self.needsModel) }
                return
            }
            update(id) { $0.state = .running(stage: stage) }
            do {
                let result = try await work { soFar in
                    await MainActor.run { AssistantStore.shared.update(id, animated: false) { $0.answer = soFar } }
                }
                try Task.checkCancellation()
                let next = followUp?(result)
                self.followUp = next?.run
                update(id) { $0.answer = result; $0.followUpTitle = next?.title; $0.state = .done }
            } catch is CancellationError {
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    static let needsModel = "This needs an AI model: Apple Intelligence, Ollama, or a cloud model's key, in Settings → Search."

    func runFollowUp() { followUp?() }

    /// Proposed commands to review, as the actions route shows them (meeting action items).
    func present(plan: CommandPlanner.Plan, query: String) {
        task?.cancel()
        var job = Job(query: query, route: .actions)
        job.plan = plan
        job.state = .done
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { current = job }
    }

    enum State: Equatable {
        case running(stage: String)
        case done
        case failed(String)
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let query: String
        var route: Route?
        var state: State = .running(stage: "Thinking")
        var files: [FileHit] = []
        var confident = true
        /// More files are being looked for while these are browsed.
        var findingMore = false
        var answer: String?
        var sources: [WebSource] = []
        var weather: WeatherReport?
        var calendar: CalendarAnswer?
        var notes: NotesAnswer?
        /// What Recall found: moments from the screen's past.
        var recall: RecallAnswer?
        /// Proposed commands for the user to review (the actions route).
        var plan: CommandPlanner.Plan?
        /// What the screen looked like, for a question about it (a small preview; nothing is saved).
        var screen: NSImage?
        /// Started by an action (an AI Command, a chip under the bar) rather than typed: the bar stays
        /// empty and shows this instead, since there's nothing in it to edit and run again.
        var actionTitle: String?
        var actionIcon: String?
        /// "Do it in this app": what could do it, best first, for a click (the app's name with them).
        var appPicks: [Command] = []
        var appName: String?
        /// A next step offered under the answer ("Add 3 action items…"), run by `runFollowUp()`.
        var followUpTitle: String?
        /// A kept call's notes: shown beside its transcript, to play from any line.
        var meeting: UUID?
        let startedAt = Date()

        var isRunning: Bool { if case .running = state { true } else { false } }
    }

    @Published private(set) var current: Job?

    /// The window captured by "Ask about this": questions go to it (follow-ups too) until it's
    /// removed or left unused for a few minutes.
    enum ContextState {
        case capturing
        case ready(ScreenContext, thumbnail: NSImage?)
        case failed(String)
    }
    @Published private(set) var context: ContextState?
    private var contextHistory: [ScreenQuestion.Exchange] = []
    private var contextTask: Task<Void, Never>?
    private var contextExpiry: DispatchWorkItem?

    var screenContext: ScreenContext? {
        if case .ready(let c, _)? = context { return c }
        return nil
    }

    /// Captures what's in front now (the keybind calls this before the notch has even opened).
    func captureContext() {
        contextTask?.cancel()
        contextHistory = []
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { context = .capturing }
        contextTask = Task {
            do {
                let captured = try await ScreenContext.capture()
                guard !Task.isCancelled else { return }
                let thumb = captured.image.flatMap(ScreenQuestion.thumbnail)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { context = .ready(captured, thumbnail: thumb) }
                touchContext()
            } catch {
                guard !Task.isCancelled else { return }
                withAnimation { context = .failed(error.localizedDescription) }
            }
        }
    }

    func clearContext() {
        contextTask?.cancel()
        contextExpiry?.cancel()
        contextHistory = []
        guard context != nil else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { context = nil }
    }

    /// Keeps the capture while it's being used; it goes after five idle minutes (the screen has moved on).
    private func touchContext() {
        contextExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clearContext() }
        contextExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }
    /// Results-as-you-type are showing (the notch grows to fit them).
    @Published var suggesting = false
    /// How many rows the results-as-you-type list shows (placeholders included), so the notch fits it.
    @Published var suggestionRows = 0
    @Published private(set) var status: OllamaClient.Status = .unknown
    @Published private(set) var pull: OllamaClient.PullProgress?
    /// Download speed in bytes per second, smoothed.
    @Published private(set) var pullSpeed: Double = 0
    /// The model that most recently finished downloading, shown briefly as a confirmation.
    @Published private(set) var justPulled: String?
    var pullProgress: Double? { pull.map { $0.fraction ?? 0 } }
    private var speedSample: (bytes: Int64, time: Date)?
    /// The model being downloaded, if any.
    @Published private(set) var pullingModel: String?
    @Published private(set) var pullError: String?
    @Published private(set) var installed: [OllamaClient.InstalledModel] = []
    private var pullTask: Task<Void, Never>?

    private var task: Task<Void, Never>?

    var runningCount: Int { current?.isRunning == true ? 1 : 0 }

    /// Without a ready model, search still works: keyword routing, Spotlight matches by name,
    /// plain web results and weather.
    var aiAvailable: Bool { status == .ready }

    // MARK: - Ollama status

    private var lastStatusCheck = Date.distantPast
    private var lastWarm = Date.distantPast

    /// For views that appear often (the Search tab on every open): checks at most every 30s, and
    /// waits for the open animation to finish so the request doesn't compete with it.
    func refreshStatusIfStale() {
        guard Date().timeIntervalSince(lastStatusCheck) > 30 else { return }
        lastStatusCheck = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refreshStatus() }
    }

    func refreshStatus() {
        lastStatusCheck = Date()
        Task {
            var s = await OllamaClient.status()
            self.installed = (try? await OllamaClient.installedModelDetails()) ?? []
            // Earlier versions saved "qwen3:8b" as the default; move to the current default unless it's installed.
            if case .modelMissing("qwen3:8b") = s, AppSettings.shared.ollamaModel != OllamaModelCatalog.defaultModel {
                AppSettings.shared.ollamaModel = OllamaModelCatalog.defaultModel
                s = .modelMissing(OllamaModelCatalog.defaultModel)
            }
            self.status = s
            // Load the model ahead of the first search, but not on every check: a warm-up runs the
            // model on the GPU, which made the notch's animations stutter when done on each open.
            // (A cloud model has nothing to load.)
            if s == .ready, AppSettings.shared.aiProvider == .local, Date().timeIntervalSince(self.lastWarm) > 600 {
                self.lastWarm = Date()
                Task.detached(priority: .background) { _ = try? await OllamaClient.chat(system: "", user: "hi") }
            }
        }
    }

    func startServer() {
        OllamaClient.startServer()
        Task {
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                let s = await OllamaClient.status()
                if s != .notRunning { self.status = s; return }
            }
            self.status = .notRunning
        }
    }

    func isInstalled(_ name: String) -> Bool {
        installed.contains { OllamaClient.matches(installed: $0.name, wanted: name) }
    }

    /// Switches the Ask tab to an installed model.
    func use(_ name: String) {
        AppSettings.shared.ollamaModel = name
        refreshStatus()
    }

    /// Downloads a model (the selected one by default) and, once it's in, switches to it.
    func pullModel(_ requested: String? = nil, switchWhenDone: Bool = true) {
        let name = OllamaClient.cleanModelName(requested ?? AppSettings.shared.ollamaModel)
        guard pullingModel == nil else { return }
        guard OllamaClient.isPlausibleModelName(name) else {
            pullError = "“\(name)” isn't a valid model name. Use a name like qwen3.5:9b."
            return
        }
        pullingModel = name
        pull = OllamaClient.PullProgress()
        pullSpeed = 0
        speedSample = nil
        pullError = nil
        failedPull = nil
        justPulled = nil
        pullTask = Task {
            do {
                try await OllamaClient.pull(name) { p in Task { @MainActor in AssistantStore.shared.updatePull(p) } }
                if switchWhenDone { AppSettings.shared.ollamaModel = name }
                self.justPulled = name
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    if AssistantStore.shared.justPulled == name { AssistantStore.shared.justPulled = nil }
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self.pullError = error.localizedDescription
                self.failedPull = name
            }
            self.pullingModel = nil
            self.pull = nil
            self.pullTask = nil
            self.refreshStatus()
        }
    }

    /// The model whose download last failed, for "Try again".
    @Published private(set) var failedPull: String?

    func cancelPull() {
        pullTask?.cancel()
    }

    func dismissPullError() {
        pullError = nil
        failedPull = nil
    }

    private func updatePull(_ p: OllamaClient.PullProgress) {
        guard pullingModel != nil else { return }
        pull = p
        let now = Date()
        if let last = speedSample {
            let dt = now.timeIntervalSince(last.time)
            if dt >= 0.5 {
                let instant = Double(p.completed - last.bytes) / dt
                pullSpeed = pullSpeed == 0 ? instant : pullSpeed * 0.7 + instant * 0.3
                speedSample = (p.completed, now)
            }
        } else {
            speedSample = (p.completed, now)
        }
    }

    func deleteModel(_ name: String) {
        Task {
            do {
                try await OllamaClient.delete(name)
            } catch {
                self.pullError = error.localizedDescription
            }
            self.refreshStatus()
        }
    }

    // MARK: - Searching

    /// Starts a search. `route` forces files or web; otherwise the model decides.
    /// `action`: the title and icon of what started it, when it wasn't typed (a chip under the bar).
    func run(_ query: String, route forced: Route? = nil, action: (title: String, icon: String)? = nil) {
        // "Try again" on a translation: the text lives in the writing task, not the query.
        if forced == .write, let writing = lastWriting { return write(writing) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // "open spotify" launches the app instead of searching for files about it.
        let (appName, explicit) = AppIndex.stripLaunchPrefix(trimmed)
        if explicit, let app = AppIndex.shared.search(appName, limit: 1).first, app.score >= 45 {
            NSWorkspace.shared.openApplication(at: app.app.url, configuration: .init())
            AppIndex.shared.noteOpened(app.app.url)
            return
        }
        // Exact commands ("timer 10m", "volume 40", "event lunch friday 1pm") run instantly, no model needed.
        if forced == nil {
            let instant = CommandParser.parse(trimmed).filter {
                if case .template = $0.action { return false }
                // "recall …" is a search: it's routed below, with its results kept.
                if case .recall = $0.action { return false }
                if case .show = $0.action { return $0.title.hasPrefix("Show") }
                return true
            }
            if instant.count == 1, instant[0].runsWithoutReview {
                task?.cancel()
                CommandCenter.shared.run(instant)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { current = nil }
                return
            }
        }
        task?.cancel()
        // "What's the answer to this question": look at the screen now, before anything on it changes.
        // With a captured window ("Ask about this"), every question is about it.
        let hasContext = context != nil && forced == nil
        // "Add this to my calendar" about a captured window: plan actions from it rather than answer.
        let actOnScreen = hasContext && ScreenQuestion.isAction(trimmed)
        let forced = actOnScreen ? .actions : forced
        let aboutScreen = !actOnScreen && (forced == .screen || hasContext
            || (forced == nil && AppSettings.shared.screenQuestions && Router.isAboutScreen(trimmed)))
        var job = Job(query: trimmed, route: aboutScreen ? .screen : forced)
        job.actionTitle = action?.title
        job.actionIcon = action?.icon
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { current = job }

        task = Task {
            let id = job.id
            let progress: @Sendable (String) async -> Void = { stage in
                await MainActor.run { AssistantStore.shared.update(id) { $0.state = .running(stage: stage) } }
            }
            var pendingMore: FileFinder.More?
            do {
                let useAI = self.aiAvailable
                if aboutScreen {
                    try await answerAboutScreen(trimmed, id: id, useAI: useAI, progress: progress)
                    throw Finished()
                }
                var chosen = forced
                if forced == .app {
                    if try await doInApp(trimmed, id: id, useAI: useAI, progress: progress) { throw Finished() }
                    // Not something the app's menus do: search for it instead.
                    chosen = nil
                    update(id) { $0.route = nil; $0.state = .running(stage: "Thinking") }
                }
                // "What was that error in Terminal yesterday": what was on screen before.
                if chosen == .recall || (chosen == nil && RecallSearch.looksLikeRecall(trimmed)) {
                    try await answerRecall(trimmed, id: id, progress: progress)
                    throw Finished()
                }
                // "What can you do", "where's the setting for…", "what's new": NotchApp's own help.
                if chosen == .help || (chosen == nil && HelpBrain.isAvailable && Router.isAboutApp(trimmed)) {
                    try await answerHelp(trimmed, id: id, useAI: useAI, progress: progress)
                    throw Finished()
                }
                var understanding = Router.understandWithoutAI(trimmed)
                if useAI, let smart = try? await Router.understand(trimmed) { understanding = smart }
                understanding.dayOffset = Router.weekendAdjusted(trimmed, dayOffset: understanding.dayOffset)
                var route = chosen ?? understanding.route
                if route == .screen, !AppSettings.shared.screenQuestions { route = .web }
                update(id) { $0.route = route }
                switch route {
                case .files:
                    let (hits, confident, more) = try await FileFinder.find(trimmed, plan: understanding.plan, useAI: useAI, progress: progress)
                    try Task.checkCancellation()
                    update(id) { $0.files = hits; $0.confident = confident; $0.state = .done; $0.findingMore = more != nil }
                    pendingMore = more
                case .web:
                    let (answer, sources) = try await WebSearcher.answer(trimmed, searchQuery: understanding.webQuery, useAI: useAI,
                                                                         progress: progress) { soFar, sources in
                        await MainActor.run { AssistantStore.shared.update(id, animated: false) { $0.answer = soFar; $0.sources = sources } }
                    }
                    try Task.checkCancellation()
                    update(id) { $0.answer = answer; $0.sources = sources; $0.state = .done }
                case .actions:
                    await progress("Planning")
                    var windowText: String?
                    if actOnScreen {
                        await contextTask?.value
                        if let c = screenContext {
                            let body = c.hasSelection ? (c.selection ?? "") : c.text
                            windowText = [c.header, String(body.prefix(4000))].filter { !$0.isEmpty }.joined(separator: "\n")
                        }
                    }
                    let plan = try await CommandPlanner.plan(trimmed, context: windowText)
                    try Task.checkCancellation()
                    guard !plan.commands.isEmpty else { throw OllamaClient.OllamaError(message: "Couldn’t turn that into an action. Try rewording it.") }
                    // One safe action ("add lunch with Sam friday 1pm", "timer 10 min") just happens, with Undo;
                    // several actions, or moving/deleting something, are shown for review first.
                    if plan.commands.count == 1, plan.commands[0].runsWithoutReview {
                        CommandCenter.shared.run(plan.commands)
                        DebugHooks.log("JOB [actions] \(trimmed) → ran \(plan.commands.map(\.title))")
                        clear()
                        return
                    }
                    update(id) { $0.plan = plan; $0.state = .done }
                case .calendar:
                    await progress("Checking your calendar")
                    let answer = try await CalendarQuery.answer(trimmed, useAI: useAI)
                    try Task.checkCancellation()
                    update(id) { $0.calendar = answer; $0.state = .done }
                case .notes:
                    await progress("Reading your notes")
                    let answer = await NotesQuery.answer(trimmed, useAI: useAI)
                    try Task.checkCancellation()
                    update(id) { $0.notes = answer; $0.state = .done }
                case .screen:
                    try await answerAboutScreen(trimmed, id: id, useAI: useAI, progress: progress)
                case .help:
                    try await answerHelp(trimmed, id: id, useAI: useAI, progress: progress)
                case .recall:
                    try await answerRecall(trimmed, id: id, progress: progress)
                case .write, .app:
                    break // writing jobs run through write(_:), app ones above (run() is handed them by route)
                case .weather:
                    await progress("Checking the forecast")
                    let report = try await WeatherService.report(location: understanding.location, dayOffset: understanding.dayOffset)
                    try Task.checkCancellation()
                    update(id) { $0.weather = report; $0.state = .done }
                }
            } catch is CancellationError {
                return
            } catch is Finished {
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
            }
            guard let finished = current, finished.id == id else { return }
            DebugHooks.log("JOB [\(finished.route?.rawValue ?? "?")] \(finished.query) → \(finished.state) \(Int(Date().timeIntervalSince(finished.startedAt)))s | files: \(finished.files.map { $0.url.lastPathComponent + " (" + ($0.reason ?? "") + ")" }) | answer: \(finished.answer ?? "")")
            announce(finished)

            // The first results are up; find the rest while they're being looked through. New ones go
            // at the end, so the selection never jumps.
            if let more = pendingMore {
                let extra = await FileFinder.more(more)
                guard !Task.isCancelled else { return }
                update(id) { job in
                    let have = Set(job.files.map(\.url))
                    job.files += extra.filter { !have.contains($0.url) }
                    job.findingMore = false
                }
                DebugHooks.log("JOB more → \(current?.files.map(\.url.lastPathComponent) ?? [])")
            }
        }
    }

    private struct Finished: Error {}

    private func answerAboutScreen(_ query: String, id: UUID, useAI: Bool,
                                   progress: @escaping @Sendable (String) async -> Void) async throws {
        guard useAI else {
            throw OllamaClient.OllamaError(message: "Questions about your screen need an AI model: start Ollama, or add a cloud model's key, in Settings → Search.")
        }
        // The window captured by "Ask about this" (waiting for it if it's still being taken), or a fresh look.
        let captured: ScreenContext
        var history: [ScreenQuestion.Exchange] = []
        if context != nil {
            await progress("Looking at your screen")
            await contextTask?.value
            if case .failed(let message)? = context { throw OllamaClient.OllamaError(message: message) }
            guard let c = screenContext else { throw CancellationError() }
            captured = c
            history = contextHistory
            touchContext()
        } else {
            await progress("Looking at your screen")
            captured = try await ScreenContext.capture()
        }
        try Task.checkCancellation()
        let preview = captured.image.flatMap(ScreenQuestion.thumbnail)
        update(id) { $0.screen = preview; $0.route = .screen }
        let (answer, sources) = try await ScreenQuestion.answer(query, context: captured, history: history,
                                                                progress: progress) { soFar, sources in
            await MainActor.run { AssistantStore.shared.update(id, animated: false) { $0.answer = soFar; $0.sources = sources } }
        }
        try Task.checkCancellation()
        update(id) { $0.answer = answer; $0.sources = sources; $0.state = .done }
        if screenContext != nil { contextHistory.append(.init(question: query, answer: answer)) }
    }

    /// Finds moments in Recall, then (for a question, with a model on this Mac) answers it in a sentence
    /// from their text. The results show while the sentence is written.
    private func answerRecall(_ query: String, id: UUID, progress: @escaping @Sendable (String) async -> Void) async throws {
        update(id) { $0.route = .recall }
        guard AppSettings.shared.recall else {
            throw OllamaClient.OllamaError(message: "Recall is off. Turn it on in Settings → Search to find things you've seen.")
        }
        await progress("Remembering")
        let filter = await RecallSearch.parse(query)
        let hits = await Task.detached(priority: .userInitiated) { RecallSearch.search(filter, query: query) }.value
        try Task.checkCancellation()
        DebugHooks.log("Recall: \(query) → \(filter) | \(hits.count) hits: \(hits.prefix(3).map { "\($0.appName ?? "?") “\($0.title ?? "")”" })")
        update(id) { $0.recall = RecallAnswer(filter: filter, hits: hits); $0.state = .done }
        // A sentence only from a model on this Mac: what was on screen never goes to the cloud.
        guard !hits.isEmpty, RecallSearch.wantsSentence(query), aiAvailable, !AppSettings.shared.aiProvider.isCloud else { return }
        let sentence = try? await RecallSearch.answer(query, hits: hits) { soFar in
            await MainActor.run { AssistantStore.shared.update(id, animated: false) { $0.recall?.sentence = soFar } }
        }
        try Task.checkCancellation()
        if let sentence, !sentence.isEmpty { update(id) { $0.recall?.sentence = sentence } }
    }

    /// Carries out an instruction in the app in front: a sure, harmless pick runs straight away (the
    /// notch steps aside for it); otherwise the picks wait for a click.
    /// Returns false when nothing in the app's menus matches, so Search can try it the usual way.
    private func doInApp(_ request: String, id: UUID, useAI: Bool, progress: @escaping @Sendable (String) async -> Void) async throws -> Bool {
        guard useAI else {
            throw AppDo.Failure(message: "Doing things in apps needs an AI model: start Ollama, or add a cloud model's key, in Settings → Search.")
        }
        let app = FrontmostTracker.shared.userApp?.localizedName ?? "the app"
        await progress("Looking through \(app)")
        let choice: AppDo.Choice
        do {
            choice = try await AppDo.choose(request)
        } catch let failure as AppDo.Failure where failure.noMatch {
            DebugHooks.log("AppDo: no match for \(request); searching instead")
            return false
        }
        try Task.checkCancellation()
        if choice.sure, let first = choice.picks.first, !AppDo.isRisky(first) {
            CommandCenter.shared.run([first])
            ActivityCenter.shared.show(.notice(title: first.title, detail: "In \(choice.app)", icon: first.icon, tone: .success), for: 2.5)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { if current?.id == id { current = nil } }
            return true
        }
        update(id) { $0.appPicks = choice.picks; $0.appName = choice.app; $0.state = .done }
        return true
    }

    /// Runs one of the picks shown for "do it in this app".
    func runAppPick(_ command: Command) {
        CommandCenter.shared.run([command])
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { current = nil }
    }

    private func answerHelp(_ query: String, id: UUID, useAI: Bool,
                            progress: @escaping @Sendable (String) async -> Void) async throws {
        update(id) { $0.route = .help }
        let (answer, sources) = try await HelpBrain.answer(query, useAI: useAI, progress: progress) { soFar, sources in
            await MainActor.run { AssistantStore.shared.update(id, animated: false) { $0.answer = soFar; $0.sources = sources } }
        }
        try Task.checkCancellation()
        update(id) { $0.answer = answer; $0.sources = sources; $0.state = .done }
    }

    /// Same question, the other way (files ↔ web).
    func switchRoute() {
        guard let job = current, let route = job.route, route != .actions, route != .calendar, route != .write else { return }
        // Files ↔ web; a weather or screen answer switches to a full web search.
        run(job.query, route: [.files, .weather, .screen, .help, .recall].contains(route) ? .web : .files)
    }

    func clear() {
        task?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { current = nil }
    }

    private func update(_ id: UUID, animated: Bool = true, _ change: (inout Job) -> Void) {
        guard current?.id == id, var job = current else { return }
        change(&job)
        if animated {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { current = job }
        } else {
            current = job
        }
    }

    /// If the notch is closed, drop down a peek (and a system notification) saying it's done.
    private func announce(_ job: Job) {
        guard NotchPresenter.shared.primary?.isOpen != true, job.route != .actions else { return }
        let title: String
        let detail: String
        switch (job.state, job.route) {
        case (.failed(let message), _):
            title = "Search failed"; detail = message
        case (_, .files?):
            if let first = job.files.first {
                title = job.confident ? "Found it" : "Possible matches"
                detail = job.files.count > 1 ? "\(first.url.lastPathComponent) + \(job.files.count - 1) more" : first.url.lastPathComponent
            } else {
                title = "No match found"; detail = job.query
            }
        case (_, .weather?):
            title = "Forecast"; detail = job.weather?.summary ?? job.query
        case (_, .calendar?):
            title = job.calendar?.headline ?? "Calendar"; detail = job.calendar?.detail ?? job.query
        case (_, .notes?):
            title = "From your notes"; detail = job.notes?.headline ?? job.query
        case (_, .recall?):
            let first = job.recall?.hits.first
            title = first == nil ? "Nothing in Recall" : "Found in Recall"
            detail = first.map { [$0.appName, $0.title].compactMap { $0 }.joined(separator: " — ") } ?? job.query
        default:
            title = "Answer ready"; detail = job.query
        }
        ActivityCenter.shared.show(.assistant(title: title, detail: detail, isWeb: job.route != .files), for: 6)
        Notifier.post(title: title, body: detail, jobID: job.id)
    }
}

/// Decides whether a request is about the user's files or the web, and prepares either search.
enum Router {
    struct Understanding: Sendable {
        var route: AssistantStore.Route
        var webQuery: String
        var plan: FileFinder.Plan
        var location: String?
        var dayOffset: Int
    }

    static func understand(_ query: String) async throws -> Understanding {
        let today = Date().formatted(date: .complete, time: .omitted)
        let system = """
        You read what the user typed into their Mac's search bar and prepare the search. Today is \(today).
        route:
        - "files": they're looking for something saved on this Mac. Anything that names or describes a specific \
        document is a file, even without the word "file": "my resume", "the lego case study for marketing", \
        "slides from chapter 8", "screenshot of the receipt", "the pdf Sarah sent", "my notes on pricing". \
        A description of what a picture shows is a file too: "a person at a desk with a card game", "the lighthouse at sunset".
        - "weather": weather, forecast, temperature or rain questions.
        - "actions": they want this app to DO something for them rather than find something: add tasks or a to-do \
        list, plan or break down a project into steps, remind them to do things, jot down or remember a note, start \
        a timer or stopwatch, add/move/cancel a calendar event, play/pause/skip music, set volume or brightness, toggle \
        dark mode/Wi-Fi/mic, lock the screen, take a screenshot, open or quit an app, tick off a task. "plan my move next month", "remind me to \
        call mom and buy eggs", "jot down the door code is 4471", "lunch with sam friday at 1", "push my 3pm to 4", \
        "add dentist appointment tuesday 10am", "cancel tomorrow's standup", "skip this song".
        - "calendar": questions about their own schedule or day, which covers their tasks too: "what's on today", \
        "what do I have to do today", "my agenda", "my schedule tomorrow", "am I free friday at 3", \
        "when is my dentist appointment", "next meeting", "what do I have this week".
        - "notes": questions about what they wrote down in this app's notes or to-do list: "what's in my notes", \
        "what did I note about the palette", "what's the door code I saved", "my tasks about the launch". \
        Not documents on the Mac ("my notes from biology class" is files).
        - "screen": a question about something on their screen right now, usually pointing at it with "this" \
        without saying what it is: "what's the answer to this question", "explain this error", "summarize this \
        page", "is this right", "translate this", "what does this mean", "help me reply to this email". \
        So is rewriting text they typed after a colon: "rewrite this more politely: send me the report now", \
        "make this shorter: …", "fix the grammar: …", "translate to french: …".
        - "help": questions about this app itself (NotchApp, "you"): what it can do, how to use one of its \
        features, where a setting is, its keyboard shortcuts, what's new in it, or why something in it isn't \
        working: "what can you do", "how do I keep screenshots", "where do I change the hover delay", \
        "how do I add a cloud model", "what's new", "why can't you see my screen".
        - "web": questions and information from the internet: facts, news, sports, prices, places, hours, how-to, \
        definitions, recommendations.
        Reply with JSON only:
        {"route": "files" or "web" or "weather" or "actions" or "calendar" or "notes" or "screen" or "help",
         "web_query": "concise search-engine query; keep time words like latest/last/this as written, don't add years",
         "location": "city for weather, or null if none given",
         "day_offset": 0 for today, 1 for tomorrow, etc. (weather only),
         "keywords": [up to 6 words likely in the file NAME or TEXT; most distinctive first; add synonyms and common abbreviations (marketing→mktg, chapter→ch, assignment→hw)],
         "kinds": [ONLY if the user names a type: pdf, word, excel, powerpoint, image, screenshot, video, audio, text, code, folder, archive],
         "days_ago_max": integer ONLY if the user mentions when (yesterday→3, last week→14, last month→45), otherwise null,
         "people": [names of people mentioned],
         "picture": true if they describe what an image shows (people, objects, a scene) rather than a document's name or contents, else false}
        """
        let obj = try await OllamaClient.chatJSON(system: system, user: query)
        let strings: (String) -> [String] = { key in
            (obj[key] as? [Any] ?? []).compactMap { $0 as? String }
                .map { $0.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }
                    .trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        var plan = FileFinder.Plan()
        plan.keywords = strings("keywords").flatMap { $0.split(separator: " ").map(String.init) }
        plan.kinds = strings("kinds").map { $0.lowercased() }
        plan.daysAgoMax = (obj["days_ago_max"] as? NSNumber)?.intValue
        plan.people = strings("people")
        plan.visual = (obj["picture"] as? Bool) ?? false
        let route = AssistantStore.Route(rawValue: (obj["route"] as? String ?? "").lowercased()) ?? .web
        let webQuery = (obj["web_query"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? query
        let location = (obj["location"] as? String).flatMap { $0.isEmpty || $0.lowercased() == "null" ? nil : $0 }
        let dayOffset = (obj["day_offset"] as? NSNumber)?.intValue ?? 0
        DebugHooks.log("Router: \(query) → \(route.rawValue) | web_query=\(webQuery) location=\(location ?? "-") day=\(dayOffset)")
        return Understanding(route: route, webQuery: webQuery, plan: plan, location: location, dayOffset: dayOffset)
    }
}

extension Router {
    /// "This weekend" means the coming Saturday (or today, at the weekend), whatever the model said.
    static func weekendAdjusted(_ query: String, dayOffset: Int) -> Int {
        guard query.lowercased().contains("weekend") else { return dayOffset }
        let weekday = Calendar.current.component(.weekday, from: Date()) // 1 = Sunday … 7 = Saturday
        return weekday == 7 || weekday == 1 ? 0 : 7 - weekday
    }

    /// Phrasings that clearly point at the screen, so they skip the router (and the screen is
    /// looked at a moment sooner).
    static func isAboutScreen(_ query: String) -> Bool {
        let lower = query.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let anywhere = ["on my screen", "on the screen", "what am i looking at", "what i'm looking at",
                        "answer to this", "answer this", "solve this", "this question", "this problem", "this quiz",
                        "this error", "this page", "this email", "this message", "this article", "this code", "this chart",
                        "this graph", "this diagram", "this equation", "this paragraph", "this window",
                        "explain this", "summarize this", "summarise this", "translate this", "is this right",
                        "is this correct", "what does this mean", "reply to this", "respond to this"]
        // "What is this" alone is about the screen; "what is this weekend's forecast" isn't.
        let whole = ["what's this", "whats this", "what is this", "check this", "fix this", "read this"]
        if whole.contains(lower) { return true }
        // "rewrite this more politely: …", "fix the grammar: …": the text is right there, after the colon.
        if lower.range(of: #"^(rewrite|reword|rephrase|proofread|shorten|simplify|fix|make|translate|polish|tidy|clean up|summari[sz]e)\b[^:]{0,40}:\s*\S"#,
                       options: .regularExpression) != nil { return true }
        return anywhere.contains { phrase in
            lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: .regularExpression) != nil
        }
    }

    /// Questions plainly about NotchApp itself, so they go straight to its help.
    static func isAboutApp(_ query: String) -> Bool {
        let l = query.lowercased().replacingOccurrences(of: "’", with: "'")
        let phrases = ["notchapp", "notch app", "this app", "what can you do", "what can u do", "what do you do",
                       "your features", "your capabilities", "capabilities", "what's new", "whats new", "changelog",
                       "release notes", "recent changes", "in settings", "in the settings", "which setting", "where is the setting",
                       "where's the setting", "the setting for", "the settings for", "how do i use you", "how do you work",
                       "your shortcuts", "my shortcuts", "glances", "add-ons", "hover delay", "fake notch"]
        return phrases.contains { phrase in
            l.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: .regularExpression) != nil
        }
    }

    /// Keyword routing for when no model is available.
    static func understandWithoutAI(_ query: String) -> Understanding {
        let lower = query.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))

        let weatherWords: Set<String> = ["weather", "forecast", "rain", "raining", "snow", "temperature", "sunny", "umbrella", "humid", "humidity"]
        if !words.isDisjoint(with: weatherWords) {
            var location: String?
            for marker in [" in ", " for ", " at "] {
                if let r = lower.range(of: marker, options: .backwards) {
                    let place = query[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                    let skip: Set<String> = ["today", "tomorrow", "tonight", "the week", "this week", "the weekend"]
                    if !place.isEmpty, !skip.contains(place.lowercased()) { location = place; break }
                }
            }
            let day = words.contains("tomorrow") ? 1 : 0
            return Understanding(route: .weather, webQuery: query, plan: .init(), location: location, dayOffset: day)
        }

        let notesPhrases = ["my notes", "in my notes", "my scratchpad", "my tasks", "my to-do", "my todo", "my to do list",
                            "did i note", "did i write down", "did i jot"]
        if notesPhrases.contains(where: { lower.contains($0) }), !lower.contains(" from "), !lower.contains(" class") {
            return Understanding(route: .notes, webQuery: query, plan: .init(), location: nil, dayOffset: 0)
        }

        let calendarPhrases = ["my calendar", "my schedule", "what's on", "whats on", "what do i have", "am i free", "am i busy",
                               "next meeting", "next event", "when am i free", "my day", "my week", "my agenda", "agenda",
                               "have to do today", "to do today", "need to do today"]
        if calendarPhrases.contains(where: { lower.contains($0) }) {
            return Understanding(route: .calendar, webQuery: query, plan: .init(), location: nil, dayOffset: 0)
        }

        let kindWords: [String: String] = [
            "pdf": "pdf", "doc": "word", "docx": "word", "word": "word", "excel": "excel", "spreadsheet": "excel",
            "xlsx": "excel", "csv": "excel", "slides": "powerpoint", "deck": "powerpoint", "powerpoint": "powerpoint",
            "pptx": "powerpoint", "keynote": "powerpoint", "image": "image", "photo": "image", "picture": "image",
            "png": "image", "jpg": "image", "screenshot": "screenshot", "video": "video", "mp4": "video", "movie": "video",
            "recording": "audio", "mp3": "audio", "audio": "audio", "folder": "folder", "zip": "archive",
        ]
        let fileWords: Set<String> = ["file", "files", "document", "doc", "resume", "cv", "notes", "invoice", "receipt",
                                      "report", "essay", "assignment", "homework", "contract", "draft", "downloaded", "saved"]
        let kinds = Array(Set(words.compactMap { kindWords[$0] }))
        let questionStarts = ["who", "what", "when", "where", "why", "how", "is", "are", "does", "do", "can", "should", "which"]
        let looksLikeQuestion = lower.hasSuffix("?") || questionStarts.contains { lower.hasPrefix($0 + " ") }
        let mentionsMine = lower.hasPrefix("my ") || lower.contains(" my ") || lower.hasPrefix("find ") || lower.hasPrefix("open ")
        let isFile = !kinds.isEmpty || !words.isDisjoint(with: fileWords) || (mentionsMine && !looksLikeQuestion)

        var plan = FileFinder.Plan()
        plan.kinds = kinds
        // Name/text keywords: what's left once type, date and filler words are removed.
        let filler: Set<String> = ["the", "and", "for", "from", "with", "that", "this", "my", "find", "open", "where", "what",
                                   "file", "files", "document", "last", "week", "month", "yesterday", "today", "sent", "about"]
        let ordered = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        plan.keywords = ordered.filter { ($0.count > 2 || $0.allSatisfy(\.isNumber)) && !filler.contains($0) && kindWords[$0] == nil }
        if words.contains("yesterday") { plan.daysAgoMax = 3 }
        else if lower.contains("last week") || lower.contains("this week") { plan.daysAgoMax = 14 }
        else if lower.contains("last month") || lower.contains("this month") { plan.daysAgoMax = 45 }
        return Understanding(route: isFile ? .files : .web, webQuery: query, plan: plan, location: nil, dayOffset: 0)
    }
}
