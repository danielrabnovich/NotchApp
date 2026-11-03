import AppKit
import Combine
import SwiftUI
import NotchKit

/// GitHub in the notch: what's waiting on you (review requests, mentions), your open pull requests
/// with their checks, and the Actions runs for what you just pushed, followed step by step.
///
/// Signs in with the `gh` command's login when there is one (NotchApp never stores it), or a token
/// pasted in Settings (kept in the Keychain). Read-only apart from re-running failed jobs and
/// marking a notification read when it's opened from the notch.
@MainActor
final class GitHubService: ObservableObject {
    static let shared = GitHubService()

    enum Connection: Equatable {
        case off
        case connecting
        /// Signed in as `login`, through `via` ("the gh command" or "a token").
        case connected(login: String, via: String)
        case failed(String)

        var login: String? { if case let .connected(login, _) = self { login } else { nil } }
    }

    struct InboxItem: Identifiable, Equatable {
        let id: String
        let reason: GitHubReason
        let title: String
        let kind: String // PullRequest, Issue, CheckSuite, Release…
        let repo: String
        let url: URL
        let updated: Date
        var unread: Bool
    }

    struct PullRequest: Identifiable, Equatable {
        enum Checks: Equatable { case none, pending, passed, failed }
        var id: String { "\(repo)#\(number)" }
        let repo: String
        let number: Int
        let title: String
        let url: URL
        let branch: String
        let headSHA: String?
        let checks: Checks
        let draft: Bool
        /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED or nil.
        let review: String?
        /// Someone wants your review (not one of yours).
        let wantsReview: Bool
        let updated: Date
    }

    /// The Actions runs for one pushed commit, followed until they're done.
    struct FollowedRun: Identifiable, Equatable {
        var id: String { "\(repo)@\(sha)" }
        let repo: String
        let sha: String
        var branch: String
        var title: String
        var ring = CIRing(steps: [])
        var runIDs: [Int] = []
        var url: URL
        let started: Date
        var finished: Date?
        /// Said the early failure already (a Banner before the rest ends).
        var warned = false
        var short: String { "\(repo.split(separator: "/").last ?? "") · \(branch)" }
    }

    @Published private(set) var connection: Connection = .off
    @Published private(set) var inbox: [InboxItem] = []
    @Published private(set) var pulls: [PullRequest] = []
    @Published private(set) var runs: [FollowedRun] = []

    /// Waiting on you: review requests plus unread mentions and assignments.
    var needsYouCount: Int {
        let reviews = pulls.filter(\.wantsReview).count
        let others = inbox.filter { $0.unread && $0.reason.needsYou && $0.reason != .reviewRequested }.count
        return reviews + others
    }

    /// Repos you're working in: your agents' folders first, then those of your pull requests.
    var knownRepos: [String] {
        var out = pushes.repos
        for pr in pulls where !pr.wantsReview && !out.contains(pr.repo) { out.append(pr.repo) }
        return out
    }

    /// The run to draw: one still going first, else the latest to finish.
    var currentRun: FollowedRun? { runs.first { $0.finished == nil } ?? runs.last }

    private var token: String?
    private var cancellables = Set<AnyCancellable>()
    private var pollTask: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    private var lastModified: String?
    private var pollInterval: TimeInterval = 60
    /// Notifications already seen, so only new ones are said.
    private var seen: [String: Date] = [:]
    private var seeded = false
    private var lastPulls: Date = .distantPast
    private var knownHeads: [String: String] = [:]
    private let pushes = PushWatcher()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "NotchApp"]
        return URLSession(configuration: c)
    }()

    // MARK: - Starting and stopping

    func start() {
        AppSettings.shared.$githubEnabled.removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async { on ? self?.connect() : self?.disconnect() }
        }.store(in: &cancellables)
        // Repos you're working in (your agents' folders) are watched for pushes.
        AgentMonitor.shared.$sessions.sink { [weak self] sessions in
            let dirs = Set(sessions.compactMap(\.directory))
            DispatchQueue.main.async { self?.pushes.watch(dirs) }
        }.store(in: &cancellables)
        pushes.onPush = { [weak self] repo, sha, branch in self?.follow(repo: repo, sha: sha, branch: branch) }
    }

    /// Signs in again (after a token was saved or `gh` logged in) and polls straight away.
    func connect() {
        guard AppSettings.shared.githubEnabled else { return }
        pollTask?.cancel()
        connection = .connecting
        pollTask = Task { [weak self] in
            guard let self else { return }
            let (token, via) = await Self.findToken()
            guard let token else {
                connection = .failed("Sign in with “gh auth login” in a terminal, or paste a token below.")
                return
            }
            self.token = token
            do {
                let user = try await get("/user")
                guard let login = (user as? [String: Any])?["login"] as? String else { throw GitHubError.message("GitHub didn't say who you are.") }
                connection = .connected(login: login, via: via)
                pushes.active = true
            } catch {
                connection = .failed(error.localizedDescription)
                return
            }
            await poll()
        }
    }

    func disconnect() {
        pollTask?.cancel()
        followTask?.cancel()
        followTask = nil
        token = nil
        pushes.active = false
        connection = .off
        inbox = []
        pulls = []
        runs = []
        seen = [:]
        seeded = false
        lastModified = nil
    }

    /// The token from the Keychain, else the gh command's.
    private static func findToken() async -> (String?, String) {
        if let saved = DevKeys.get("github") { return (saved, "a token") }
        for gh in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: gh) {
            let r = await Shell.run(gh, ["auth", "token"], timeout: 10)
            let t = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.ok, !t.isEmpty { return (t, "the gh command") }
        }
        return (nil, "")
    }

    static var hasGH: Bool { ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].contains { FileManager.default.isExecutableFile(atPath: $0) } }

    // MARK: - Polling

    private func poll() async {
        while !Task.isCancelled, connection.login != nil {
            await pollNotifications()
            if Date().timeIntervalSince(lastPulls) > 110 {
                lastPulls = Date()
                await pollPulls()
            }
            try? await Task.sleep(for: .seconds(max(60, pollInterval)))
        }
    }

    /// Unread notifications; new ones become Banners (or a Prompt for a review request).
    private func pollNotifications() async {
        var headers: [String: String] = [:]
        if let lastModified { headers["If-Modified-Since"] = lastModified }
        guard let (data, response) = try? await request("/notifications?per_page=50", headers: headers) else { return }
        if let interval = response.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(Double.init) { pollInterval = interval }
        if response.statusCode == 304 { return }
        guard response.statusCode == 200, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        let items = list.compactMap(Self.inboxItem)
        let fresh = items.filter { item in seen[item.id].map { item.updated > $0 } ?? true }
        for item in items { seen[item.id] = item.updated }
        inbox = items
        if seeded { fresh.reversed().forEach(announce) }
        seeded = true
    }

    private static func inboxItem(_ n: [String: Any]) -> InboxItem? {
        guard let id = n["id"] as? String, let subject = n["subject"] as? [String: Any],
              let repo = (n["repository"] as? [String: Any])?["full_name"] as? String else { return nil }
        let updated = (n["updated_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) } ?? Date()
        return InboxItem(id: id, reason: GitHubReason(api: n["reason"] as? String ?? ""), title: subject["title"] as? String ?? "",
                         kind: subject["type"] as? String ?? "", repo: repo,
                         url: GitHubLinks.web(api: subject["url"] as? String, repo: repo), updated: updated,
                         unread: n["unread"] as? Bool ?? true)
    }

    /// Your open pull requests and the ones waiting for your review, with their checks.
    private func pollPulls() async {
        guard let login = connection.login else { return }
        let fields = """
        nodes { ... on PullRequest { number title url isDraft updatedAt headRefName reviewDecision
          repository { nameWithOwner }
          commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } } } }
        """
        let query = """
        query { mine: search(query: "is:open is:pr archived:false author:\(login)", type: ISSUE, first: 20) { \(fields) }
          review: search(query: "is:open is:pr archived:false review-requested:\(login)", type: ISSUE, first: 20) { \(fields) } }
        """
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": query]),
              let (data, response) = try? await request("/graphql", method: "POST", body: body), response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["data"] as? [String: Any] else { return }
        func parse(_ key: String, review: Bool) -> [PullRequest] {
            let nodes = (result[key] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            return nodes.compactMap { n in
                guard let number = n["number"] as? Int, let url = (n["url"] as? String).flatMap(URL.init(string:)),
                      let repo = (n["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
                let commit = (((n["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"]) as? [String: Any]
                let state = (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String
                let checks: PullRequest.Checks = switch state {
                case "SUCCESS": .passed
                case "FAILURE", "ERROR": .failed
                case "PENDING", "EXPECTED": .pending
                default: .none
                }
                return PullRequest(repo: repo, number: number, title: n["title"] as? String ?? "", url: url,
                                   branch: n["headRefName"] as? String ?? "", headSHA: commit?["oid"] as? String, checks: checks,
                                   draft: n["isDraft"] as? Bool ?? false, review: n["reviewDecision"] as? String, wantsReview: review,
                                   updated: (n["updatedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) } ?? Date())
            }
        }
        let mine = parse("mine", review: false), wanted = parse("review", review: true)
        // A new commit on one of yours with checks under way (pushed from anywhere): follow it.
        for pr in mine {
            guard let sha = pr.headSHA else { continue }
            if let known = knownHeads[pr.id], known != sha, pr.checks == .pending {
                follow(repo: pr.repo, sha: sha, branch: pr.branch, title: pr.title)
            }
            knownHeads[pr.id] = sha
        }
        pulls = wanted + mine.sorted { $0.updated > $1.updated }
    }

    // MARK: - Following a push

    /// Follows the Actions runs for a commit just pushed, step by step.
    func follow(repo: String, sha: String, branch: String, title: String? = nil) {
        guard connection.login != nil, !runs.contains(where: { $0.repo == repo && $0.sha == sha }) else { return }
        let run = FollowedRun(repo: repo, sha: sha, branch: branch, title: title ?? branch,
                              url: URL(string: "https://github.com/\(repo)/commit/\(sha)/checks")!, started: Date())
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { runs.append(run) }
        startFollowing()
    }

    private func startFollowing() {
        guard followTask == nil else { return }
        followTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.runs.contains(where: { $0.finished == nil }) {
                for run in self.runs where run.finished == nil { await self.refresh(run) }
                try? await Task.sleep(for: .seconds(4))
            }
            self?.followTask = nil
        }
    }

    private func refresh(_ run: FollowedRun) async {
        guard let list = try? await get("/repos/\(run.repo)/actions/runs?head_sha=\(run.sha)&per_page=20") as? [String: Any],
              let found = list["workflow_runs"] as? [[String: Any]] else { return }
        // Nothing yet: Actions can take a few seconds to start. A repo without any gives up quietly.
        guard !found.isEmpty else {
            if Date().timeIntervalSince(run.started) > 90 { update(run.id) { $0.finished = Date() }; drop(run.id, after: 0) }
            return
        }
        var jobs: [CIRing.Job] = []
        for r in found.sorted(by: { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }) {
            guard let id = r["id"] as? Int,
                  let j = try? await get("/repos/\(run.repo)/actions/runs/\(id)/jobs?per_page=100") as? [String: Any] else { continue }
            for job in j["jobs"] as? [[String: Any]] ?? [] {
                let steps = (job["steps"] as? [[String: Any]] ?? []).map {
                    (name: $0["name"] as? String ?? "", status: $0["status"] as? String, conclusion: $0["conclusion"] as? String)
                }
                jobs.append(.init(name: job["name"] as? String ?? "", status: job["status"] as? String,
                                  conclusion: job["conclusion"] as? String, steps: steps))
            }
        }
        let ring = CIRing(jobs: jobs)
        let first = found.first
        update(run.id) {
            $0.ring = ring
            $0.runIDs = found.compactMap { $0["id"] as? Int }
            if let title = first?["display_title"] as? String, !title.isEmpty { $0.title = title }
            if found.count == 1, let url = (first?["html_url"] as? String).flatMap(URL.init(string:)) { $0.url = url }
        }
        // Every run says it's done (the jobs can lag a moment behind).
        let allDone = found.allSatisfy { ($0["status"] as? String) == "completed" }
        if allDone, ring.outcome != .running || jobs.isEmpty { finish(run.id) }
        else if ring.hasFailure, let current = runs.first(where: { $0.id == run.id }), !current.warned {
            update(run.id) { $0.warned = true }
            if let failed = ring.current {
                ActivityCenter.shared.show(.notice(title: "\(failed.job) failed", detail: "\(run.short) · others still running",
                                                   icon: "xmark.octagon.fill", tone: .warning), for: 5) { NSWorkspace.shared.open(current.url) }
            }
        }
    }

    private func finish(_ id: String) {
        update(id) { $0.finished = Date() }
        guard let run = runs.first(where: { $0.id == id }) else { return }
        let took = CommandHandler.duration(Date().timeIntervalSince(run.started))
        switch run.ring.outcome {
        case .passed, .running:
            ActivityCenter.shared.show(.notice(title: "Checks passed", detail: "\(run.short) · \(run.ring.jobsTotal) job\(run.ring.jobsTotal == 1 ? "" : "s") in \(took)",
                                               icon: "checkmark.circle.fill", tone: .success), for: 5) { NSWorkspace.shared.open(run.url) }
        case .cancelled:
            ActivityCenter.shared.show(.notice(title: "Checks cancelled", detail: run.short, icon: "stop.circle.fill", tone: .info), for: 4) {
                NSWorkspace.shared.open(run.url)
            }
        case .failed:
            let step = run.ring.current
            let prompt = Prompt(icon: "xmark.octagon.fill", tint: .systemRed, title: "CI failed: \(step?.job ?? run.branch)",
                                detail: [step.map { "“\($0.name)”" }, run.short].compactMap { $0 }.joined(separator: " · "),
                                actions: [.init(title: "Open Logs", primary: true) { NSWorkspace.shared.open(run.url) },
                                          .init(title: "Re-run Failed") { [weak self] in self?.rerunFailed(run) }])
            NotchPresenter.shared.offer(prompt, peekFor: 8)
        }
        drop(id, after: 30)
    }

    /// Takes a finished run off the Glance after a while.
    private func drop(_ id: String, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, runs.first(where: { $0.id == id })?.finished != nil else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self.runs.removeAll { $0.id == id } }
        }
    }

    private func update(_ id: String, _ change: (inout FollowedRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[i])
    }

    /// Re-runs the failed jobs of a run's workflows, and follows them again.
    func rerunFailed(_ run: FollowedRun) {
        Task {
            var ok = false
            for id in run.runIDs {
                if let (_, r) = try? await request("/repos/\(run.repo)/actions/runs/\(id)/rerun-failed-jobs", method: "POST"),
                   (200..<300).contains(r.statusCode) { ok = true }
            }
            if ok {
                runs.removeAll { $0.id == run.id }
                follow(repo: run.repo, sha: run.sha, branch: run.branch, title: run.title)
            } else {
                ActivityCenter.shared.show(.notice(title: "Couldn't re-run", detail: "GitHub said no: open the run to try there",
                                                   icon: "exclamationmark.triangle.fill", tone: .warning), for: 4) { NSWorkspace.shared.open(run.url) }
            }
        }
    }

    // MARK: - Saying it

    private func announce(_ item: InboxItem) {
        let level = AppSettings.shared.githubAlerts
        let loudness = item.reason.loudness
        guard level != .off, loudness > .quiet, level == .everything || loudness >= .aboutYou else { return }
        // A run being followed on the Glance says how it went itself.
        if item.reason == .ciActivity, !runs.isEmpty { return }
        let repo = String(item.repo.split(separator: "/").last ?? "")
        let open: @MainActor () -> Void = { [weak self] in self?.open(item) }
        switch loudness {
        case .waitingOnYou:
            NotchPresenter.shared.offer(Prompt(icon: "eye.fill", tint: .systemOrange, title: "Review requested",
                                               detail: "\(item.title) · \(repo)",
                                               actions: [.init(title: "Open", primary: true, run: open)], dismissTitle: "Later"), peekFor: 7)
        default:
            let (title, icon): (String, String) = switch item.reason {
            case .mention, .teamMention: ("Mentioned in \(repo)", "at")
            case .assign: ("Assigned to you", "person.crop.circle.badge.checkmark")
            case .securityAlert: ("Security alert in \(repo)", "exclamationmark.shield.fill")
            case .ciActivity: ("Actions in \(repo)", "gearshape.2.fill")
            case .stateChange: ("\(item.kind == "PullRequest" ? "Pull request" : "Issue") changed", "arrow.triangle.pull")
            default: ("New in \(repo)", "bubble.left.fill")
            }
            ActivityCenter.shared.show(.notice(title: title, detail: item.title, icon: icon,
                                               tone: item.reason == .securityAlert ? .warning : .info), for: 5, onClick: open)
        }
    }

    /// Opens a notification's page and marks it read.
    func open(_ item: InboxItem) {
        NSWorkspace.shared.open(item.url)
        guard item.unread else { return }
        if let i = inbox.firstIndex(where: { $0.id == item.id }) { inbox[i].unread = false }
        Task { _ = try? await request("/notifications/threads/\(item.id)", method: "PATCH") }
    }

    func open(_ pr: PullRequest) { NSWorkspace.shared.open(pr.url) }

    /// The Glance's click: the run on it, else what's waiting on you, else your pull requests.
    func openTop() {
        if let run = currentRun { NSWorkspace.shared.open(run.url) }
        else if let pr = pulls.first(where: \.wantsReview) { open(pr) }
        else if let item = inbox.first(where: { $0.unread && $0.reason.needsYou }) { open(item) }
        else { NSWorkspace.shared.open(URL(string: "https://github.com/pulls")!) }
    }

    // MARK: - Requests

    enum GitHubError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(m) = self { m } else { nil } }
    }

    func get(_ path: String) async throws -> Any {
        let (data, r) = try await request(path)
        guard r.statusCode == 200 else {
            throw GitHubError.message(r.statusCode == 401 ? "GitHub didn't accept the sign-in. Sign in again." : "GitHub answered \(r.statusCode).")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil,
                         headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let token else { throw GitHubError.message("Not signed in.") }
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.message("No answer from GitHub.") }
        if http.statusCode == 401, connection.login != nil { connection = .failed("GitHub didn't accept the sign-in. Sign in again.") }
        return (data, http)
    }

    // MARK: - Debug and demo

    /// A pretend run that moves through its steps, for trying the ring without pushing anything.
    func simulate(fail: Bool) {
        let id = "demo/notch@\(UUID().uuidString.prefix(8))"
        let sha = String(id.split(separator: "@").last!)
        var run = FollowedRun(repo: "demo/notch", sha: sha, branch: "feat/glass", title: "Glass edge sync",
                              url: URL(string: "https://github.com")!, started: Date())
        let names = [("Build", ["Checkout", "Set up Swift", "Resolve", "Build", "Archive"]), ("Test", ["Checkout", "Unit tests", "UI tests"]),
                     ("Lint", ["Checkout", "SwiftLint"])]
        func ring(at tick: Int) -> CIRing {
            var n = 0
            return CIRing(steps: names.flatMap { job, steps in
                steps.map { name -> CIRing.Step in
                    defer { n += 1 }
                    let state: CIStepState = fail && n == 6 && tick > n ? .failure : n < tick ? .success : n == tick ? .running : .queued
                    return .init(job: job, name: name, state: state)
                }
            })
        }
        run.ring = ring(at: 0)
        runs.append(run)
        let total = names.reduce(0) { $0 + $1.1.count }
        for tick in 1...total {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(tick) * 1.5) { [weak self] in
                guard let self else { return }
                update(run.id) { $0.ring = ring(at: tick) }
                if tick == total { finish(run.id) }
            }
        }
    }
}

/// Watches repos for `git push`: the remote branch's reflog says "update by push" with the new commit.
@MainActor
final class PushWatcher {
    var onPush: ((_ repo: String, _ sha: String, _ branch: String) -> Void)?
    var active = false { didSet { if active != oldValue { restart() } } }

    private var roots: [String: String] = [:] // git dir (common) → owner/repo
    /// The GitHub repos being watched (where your agents work).
    var repos: [String] { Array(Set(roots.values)).sorted() }
    private var directories: Set<String> = []
    private var stream: FSEventStreamRef?
    private var lastLines: [String: String] = [:]

    func watch(_ dirs: Set<String>) {
        guard dirs != directories else { return }
        directories = dirs
        Task {
            var found: [String: String] = [:]
            for dir in dirs {
                let common = await Shell.run("/usr/bin/git", ["-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir"], timeout: 5)
                let remote = await Shell.run("/usr/bin/git", ["-C", dir, "remote", "get-url", "origin"], timeout: 5)
                guard common.ok, remote.ok, let repo = GitHubLinks.repo(remote: remote.out) else { continue }
                found[common.out.trimmingCharacters(in: .whitespacesAndNewlines)] = repo
            }
            if found != roots {
                roots = found
                restart()
            }
        }
    }

    private func restart() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard active, !roots.isEmpty else { return }
        let paths = roots.keys.map { "\($0)/logs/refs/remotes" } as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<PushWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { list.prefix(count).forEach(watcher.changed) }
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    /// A reflog file under logs/refs/remotes/<remote>/<branch…> changed.
    private func changed(_ path: String) {
        guard let (root, repo) = roots.first(where: { path.hasPrefix($0.key + "/logs/refs/remotes/") }),
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let line = text.split(separator: "\n").last.map(String.init), lastLines[path] != line else { return }
        lastLines[path] = line
        guard let sha = GitHubLinks.pushedSHA(reflogLine: line) else { return }
        // logs/refs/remotes/origin/feat/x → feat/x
        let rest = path.dropFirst((root + "/logs/refs/remotes/").count).split(separator: "/").dropFirst()
        onPush?(repo, sha, rest.joined(separator: "/"))
    }
}

/// Tokens for developer services, in the login Keychain (never in preferences).
enum DevKeys {
    private static let service = "com.notchapp.NotchApp.dev"

    static func get(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func set(_ key: String?, for account: String) {
        SecItemDelete(base(account) as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var item = base(account)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
