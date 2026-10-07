import AppKit
import SwiftUI

/// The Ask tab's search: one query at a time, routed automatically to the user's files or the web.
/// It keeps running in the background if the notch closes and announces itself when done.
@MainActor
final class AssistantStore: ObservableObject {
    static let shared = AssistantStore()

    enum Route: String { case files, web, weather }

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
        var answer: String?
        var sources: [WebSource] = []
        var weather: WeatherReport?
        let startedAt = Date()

        var isRunning: Bool { if case .running = state { true } else { false } }
    }

    @Published private(set) var current: Job?
    @Published private(set) var status: OllamaClient.Status = .unknown
    @Published private(set) var pullProgress: Double?

    private var task: Task<Void, Never>?

    var runningCount: Int { current?.isRunning == true ? 1 : 0 }

    // MARK: - Ollama status

    func refreshStatus() {
        Task {
            let s = await OllamaClient.status()
            self.status = s
            if s == .ready { Task.detached { _ = try? await OllamaClient.chat(system: "", user: "hi") } } // warm the model
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

    func pullModel() {
        let name = AppSettings.shared.ollamaModel
        pullProgress = 0
        Task {
            do {
                try await OllamaClient.pull(name) { p in Task { @MainActor in AssistantStore.shared.pullProgress = p } }
            } catch {
                NSLog("NotchApp: pull failed: \(error)")
            }
            self.pullProgress = nil
            self.refreshStatus()
        }
    }

    // MARK: - Searching

    /// Starts a search. `route` forces files or web; otherwise the model decides.
    func run(_ query: String, route forced: Route? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        let job = Job(query: trimmed, route: forced)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { current = job }

        task = Task {
            let id = job.id
            let progress: @Sendable (String) async -> Void = { stage in
                await MainActor.run { AssistantStore.shared.update(id) { $0.state = .running(stage: stage) } }
            }
            do {
                let understanding = try await Router.understand(trimmed)
                let route = forced ?? understanding.route
                update(id) { $0.route = route }
                switch route {
                case .files:
                    let (hits, confident) = try await FileFinder.find(trimmed, plan: understanding.plan, progress: progress)
                    try Task.checkCancellation()
                    update(id) { $0.files = hits; $0.confident = confident; $0.state = .done }
                case .web:
                    let (answer, sources) = try await WebSearcher.answer(trimmed, searchQuery: understanding.webQuery, progress: progress) { soFar, sources in
                        await MainActor.run { AssistantStore.shared.update(id, animated: false) { $0.answer = soFar; $0.sources = sources } }
                    }
                    try Task.checkCancellation()
                    update(id) { $0.answer = answer; $0.sources = sources; $0.state = .done }
                case .weather:
                    await progress("Checking the forecast")
                    let report = try await WeatherService.report(location: understanding.location, dayOffset: understanding.dayOffset)
                    try Task.checkCancellation()
                    update(id) { $0.weather = report; $0.state = .done }
                }
            } catch is CancellationError {
                return
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
            }
            guard let finished = current, finished.id == id else { return }
            DebugHooks.log("JOB [\(finished.route?.rawValue ?? "?")] \(finished.query) → \(finished.state) \(Int(Date().timeIntervalSince(finished.startedAt)))s | files: \(finished.files.map { $0.url.lastPathComponent + " (" + ($0.reason ?? "") + ")" }) | answer: \(finished.answer ?? "")")
            announce(finished)
        }
    }

    /// Same question, the other way (files ↔ web).
    func switchRoute() {
        guard let job = current, let route = job.route else { return }
        // Files ↔ web; a weather answer switches to a full web search.
        run(job.query, route: route == .files || route == .weather ? .web : .files)
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
        guard NotchPresenter.shared.primary?.isOpen != true else { return }
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
        "slides from chapter 8", "screenshot of the receipt", "the pdf Sarah sent", "my notes on pricing".
        - "weather": weather, forecast, temperature or rain questions.
        - "web": questions and information from the internet: facts, news, sports, prices, places, hours, how-to, \
        definitions, recommendations.
        Reply with JSON only:
        {"route": "files" or "web" or "weather",
         "web_query": "concise search-engine query; keep time words like latest/last/this as written, don't add years",
         "location": "city for weather, or null if none given",
         "day_offset": 0 for today, 1 for tomorrow, etc. (weather only),
         "keywords": [up to 6 words likely in the file NAME or TEXT; most distinctive first; add synonyms and common abbreviations (marketing→mktg, chapter→ch, assignment→hw)],
         "kinds": [ONLY if the user names a type: pdf, word, excel, powerpoint, image, screenshot, video, audio, text, code, folder, archive],
         "days_ago_max": integer ONLY if the user mentions when (yesterday→3, last week→14, last month→45), otherwise null,
         "people": [names of people mentioned]}
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
        let route = AssistantStore.Route(rawValue: (obj["route"] as? String ?? "").lowercased()) ?? .web
        let webQuery = (obj["web_query"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? query
        let location = (obj["location"] as? String).flatMap { $0.isEmpty || $0.lowercased() == "null" ? nil : $0 }
        let dayOffset = (obj["day_offset"] as? NSNumber)?.intValue ?? 0
        DebugHooks.log("Router: \(query) → \(route.rawValue) | web_query=\(webQuery) location=\(location ?? "-") day=\(dayOffset)")
        return Understanding(route: route, webQuery: webQuery, plan: plan, location: location, dayOffset: dayOffset)
    }
}
