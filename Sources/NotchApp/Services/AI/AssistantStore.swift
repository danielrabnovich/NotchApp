import AppKit
import SwiftUI

/// The Ask tab's search: one query at a time, routed automatically to the user's files or the web.
/// It keeps running in the background if the notch closes and announces itself when done.
@MainActor
final class AssistantStore: ObservableObject {
    static let shared = AssistantStore()

    enum Route: String { case files, web, weather, actions, calendar, notes, screen }

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
        /// Proposed commands for the user to review (the actions route).
        var plan: CommandPlanner.Plan?
        /// What the screen looked like, for a question about it (a small preview; nothing is saved).
        var screen: NSImage?
        let startedAt = Date()

        var isRunning: Bool { if case .running = state { true } else { false } }
    }

    @Published private(set) var current: Job?
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
            if s == .ready, Date().timeIntervalSince(self.lastWarm) > 600 {
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
    func run(_ query: String, route forced: Route? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // "open spotify" launches the app instead of searching for files about it.
        let (appName, explicit) = AppIndex.stripLaunchPrefix(trimmed)
        if explicit, let app = AppIndex.shared.search(appName, limit: 1).first, app.score >= 45 {
            NSWorkspace.shared.openApplication(at: app.app.url, configuration: .init())
            return
        }
        // Exact commands ("timer 10m", "volume 40", "event lunch friday 1pm") run instantly, no model needed.
        if forced == nil {
            let instant = CommandParser.parse(trimmed).filter {
                if case .template = $0.action { return false }
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
        let aboutScreen = forced == .screen || (forced == nil && AppSettings.shared.screenQuestions && Router.isAboutScreen(trimmed))
        let job = Job(query: trimmed, route: aboutScreen ? .screen : forced)
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
                var understanding = Router.understandWithoutAI(trimmed)
                if useAI, let smart = try? await Router.understand(trimmed) { understanding = smart }
                understanding.dayOffset = Router.weekendAdjusted(trimmed, dayOffset: understanding.dayOffset)
                var route = forced ?? understanding.route
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
                    let plan = try await CommandPlanner.plan(trimmed)
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
            throw OllamaClient.OllamaError(message: "Questions about your screen need the local model. Start Ollama in Settings → AI.")
        }
        await progress("Looking at your screen")
        let capture = try await ScreenQuestion.capture()
        try Task.checkCancellation()
        let preview = ScreenQuestion.thumbnail(capture.image)
        update(id) { $0.screen = preview; $0.route = .screen }
        let (answer, sources) = try await ScreenQuestion.answer(query, capture: capture, progress: progress) { soFar, sources in
            await MainActor.run { AssistantStore.shared.update(id, animated: false) { $0.answer = soFar; $0.sources = sources } }
        }
        try Task.checkCancellation()
        update(id) { $0.answer = answer; $0.sources = sources; $0.state = .done }
    }

    /// Same question, the other way (files ↔ web).
    func switchRoute() {
        guard let job = current, let route = job.route, route != .actions, route != .calendar else { return }
        // Files ↔ web; a weather or screen answer switches to a full web search.
        run(job.query, route: [.files, .weather, .screen].contains(route) ? .web : .files)
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
        page", "is this right", "translate this", "what does this mean", "help me reply to this email".
        - "web": questions and information from the internet: facts, news, sports, prices, places, hours, how-to, \
        definitions, recommendations.
        Reply with JSON only:
        {"route": "files" or "web" or "weather" or "actions" or "calendar" or "notes" or "screen",
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
        return anywhere.contains { phrase in
            lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: .regularExpression) != nil
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
