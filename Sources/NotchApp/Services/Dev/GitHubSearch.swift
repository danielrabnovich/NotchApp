import AppKit
import NotchKit

/// What Search shows for a GitHub question: one pull request in full, a list of them (or issues),
/// or recent Actions runs.
struct GitHubAnswer: Equatable {
    struct Pull: Equatable {
        enum State: String { case open, draft, merged, closed }
        let repo: String
        let number: Int
        let title: String
        let url: URL
        let state: State
        let author: String
        let head: String
        let base: String
        let additions: Int
        let deletions: Int
        let files: Int
        let comments: Int
        /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED or nil.
        let review: String?
        /// Each check (an Actions job, another app's check, a commit status) as one segment.
        let checks: CIRing
        let checkLinks: [String: URL]
        /// The Actions runs behind the checks, for Re-run Failed.
        let runIDs: [Int]
        let labels: [String]
        let mergeable: Bool?
        let updated: Date
    }

    struct Item: Identifiable, Equatable {
        var id: String { "\(repo)#\(number)" }
        let repo: String
        let number: Int
        let title: String
        let url: URL
        let isPull: Bool
        let state: Pull.State
        let checks: GitHubService.PullRequest.Checks
        let wantsReview: Bool
        let author: String
        let comments: Int
        let updated: Date
    }

    struct Run: Identifiable, Equatable {
        let id: Int
        let repo: String
        let workflow: String
        let title: String
        let branch: String
        let event: String
        let state: CIStepState
        let url: URL
        let started: Date
        let ended: Date?
        /// Being followed on the Glance: its ring, step by step.
        var ring: CIRing?
    }

    var headline: String
    var detail: String?
    var pull: Pull?
    var items: [Item] = []
    var runs: [Run] = []
    /// The items are the same number in different repos: ↩ shows the chosen one here in full.
    var choices = false

    /// What ↑↓ and ↩ go through.
    var links: [URL] { pull.map { [$0.url] } ?? (items.isEmpty ? runs.map(\.url) : items.map(\.url)) }

    /// A line for the Banner when it finishes with the notch closed.
    var summary: String { detail ?? headline }
}

@MainActor
enum GitHubSearch {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Whether Search should hand this query to GitHub.
    static func understands(_ query: String) -> Bool {
        AppSettings.shared.githubEnabled && GitHubService.shared.connection.login != nil && GitHubQuery.parse(query) != nil
    }

    static func answer(_ query: String) async throws -> GitHubAnswer {
        let github = GitHubService.shared
        guard let login = github.connection.login else { throw Failure(message: "Sign in to GitHub in Settings › Developer.") }
        switch GitHubQuery.parse(query) ?? .search(text: query, pulls: true) {
        case let .pull(repo, number):
            return try await pull(repo: repo, number: number)
        case .mine:
            let items = try await search("is:open is:pr archived:false author:\(login)")
            return GitHubAnswer(headline: "Your pull requests", detail: count(items, "open"), items: items)
        case .reviews:
            let items = try await search("is:open is:pr archived:false review-requested:\(login)", wantsReview: true)
            return GitHubAnswer(headline: items.isEmpty ? "Nothing waiting for your review" : "Waiting for your review",
                                detail: items.isEmpty ? "You're all caught up" : count(items, "to review"), items: items)
        case .mentions:
            let items = try await search("is:open archived:false mentions:\(login) sort:updated-desc")
            return GitHubAnswer(headline: "Where you're mentioned", detail: count(items, "open"), items: items)
        case .runs:
            let runs = try await recentRuns()
            return GitHubAnswer(headline: "Recent Actions runs",
                                detail: runs.isEmpty ? "No runs in the repos you're working in" : running(runs), runs: runs)
        case let .search(text, pulls):
            let items = try await search("\(text) is:\(pulls ? "pr" : "issue") archived:false involves:\(login) sort:updated-desc")
            return GitHubAnswer(headline: "\(pulls ? "Pull requests" : "Issues") matching “\(text)”", detail: count(items, "found"), items: items)
        }
    }

    private static func count(_ items: [GitHubAnswer.Item], _ word: String) -> String {
        "\(items.count) \(word)"
    }

    private static func running(_ runs: [GitHubAnswer.Run]) -> String {
        let going = runs.filter { !$0.state.isDone }.count, failed = runs.filter { $0.state == .failure }.count
        return [going > 0 ? "\(going) running" : nil, failed > 0 ? "\(failed) failed" : nil, "\(runs.count) recent"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - One pull request

    private static let pullFields = """
    number title url state isDraft additions deletions changedFiles reviewDecision mergeable updatedAt
    author { login } baseRefName headRefName comments { totalCount } labels(first: 6) { nodes { name } }
    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 60) { nodes {
      __typename ... on CheckRun { name status conclusion detailsUrl checkSuite { workflowRun { databaseId workflow { name } } } }
      ... on StatusContext { context state targetUrl } } } } } } }
    """

    private static func pull(repo: String?, number: Int) async throws -> GitHubAnswer {
        let github = GitHubService.shared
        // A number alone: the repo among your pull requests with it, else the repos you're working in.
        var candidates: [String] = []
        if let repo { candidates = [repo] } else {
            candidates = github.pulls.filter { $0.number == number }.map(\.repo) + github.knownRepos
        }
        var seen = Set<String>()
        let repos = Array(candidates.filter { seen.insert($0).inserted }.prefix(6))
        // Every likely repo at once; the same number can be a pull request in several of them.
        var found: [(Int, GitHubAnswer.Pull)] = []
        await withTaskGroup(of: (Int, GitHubAnswer.Pull)?.self) { group in
            for (rank, repo) in repos.enumerated() {
                group.addTask { @MainActor in
                    let parts = repo.split(separator: "/")
                    guard parts.count == 2 else { return nil }
                    let query = "query { repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { pullRequest(number: \(number)) { \(pullFields) } } }"
                    guard let node = try? await graphQL(query)?["repository"] as? [String: Any],
                          let pr = node["pullRequest"] as? [String: Any], let pull = parsePull(pr, repo: repo) else { return nil }
                    return (rank, pull)
                }
            }
            for await result in group { if let result { found.append(result) } }
        }
        // In the order they were looked for: yours and the ones you're asked to review first, then where you work.
        let pulls = found.sorted { $0.0 < $1.0 }.map(\.1)
        if pulls.count == 1, let only = pulls.first {
            return GitHubAnswer(headline: only.title, detail: "\(only.repo)#\(number)", pull: only)
        }
        if pulls.count > 1 {
            let items = pulls.map { p in
                GitHubAnswer.Item(repo: p.repo, number: p.number, title: p.title, url: p.url, isPull: true, state: p.state,
                                  checks: p.checks.steps.isEmpty ? .none : p.checks.hasFailure ? .failed : p.checks.outcome == .running ? .pending : .passed,
                                  wantsReview: github.pulls.contains { $0.repo == p.repo && $0.number == p.number && $0.wantsReview },
                                  author: p.author, comments: p.comments, updated: p.updated)
            }
            return GitHubAnswer(headline: "#\(number) is in \(pulls.count) repos", detail: "↩ shows one here", items: items, choices: true)
        }
        throw Failure(message: repo == nil
                      ? "No pull request #\(number) in the repos you're working in. Try owner/repo#\(number)."
                      : "No pull request #\(number) in \(repo!).")
    }

    private static func parsePull(_ pr: [String: Any], repo: String) -> GitHubAnswer.Pull? {
        guard let number = pr["number"] as? Int, let url = (pr["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        var steps: [CIRing.Step] = [], links: [String: URL] = [:], runIDs: [Int] = []
        let commit = (((pr["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"]) as? [String: Any]
        let contexts = (((commit?["statusCheckRollup"] as? [String: Any])?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        for c in contexts {
            if c["__typename"] as? String == "CheckRun" {
                let name = c["name"] as? String ?? "Check"
                let run = ((c["checkSuite"] as? [String: Any])?["workflowRun"] as? [String: Any])
                let workflow = ((run?["workflow"] as? [String: Any])?["name"] as? String) ?? name
                if let id = run?["databaseId"] as? Int, !runIDs.contains(id) { runIDs.append(id) }
                let state = CIStepState(status: (c["status"] as? String)?.lowercased(), conclusion: (c["conclusion"] as? String)?.lowercased())
                steps.append(.init(job: workflow, name: name, state: state))
                if let link = (c["detailsUrl"] as? String).flatMap(URL.init(string:)) { links[name] = link }
            } else {
                let name = c["context"] as? String ?? "Status"
                let state: CIStepState = switch c["state"] as? String {
                case "SUCCESS": .success
                case "FAILURE", "ERROR": .failure
                case "PENDING", "EXPECTED": .running
                default: .queued
                }
                steps.append(.init(job: name, name: name, state: state))
                if let link = (c["targetUrl"] as? String).flatMap(URL.init(string:)) { links[name] = link }
            }
        }
        let raw = pr["state"] as? String
        let state: GitHubAnswer.Pull.State = raw == "MERGED" ? .merged : raw == "CLOSED" ? .closed : (pr["isDraft"] as? Bool ?? false) ? .draft : .open
        return .init(repo: repo, number: number, title: pr["title"] as? String ?? "", url: url, state: state,
                     author: (pr["author"] as? [String: Any])?["login"] as? String ?? "",
                     head: pr["headRefName"] as? String ?? "", base: pr["baseRefName"] as? String ?? "",
                     additions: pr["additions"] as? Int ?? 0, deletions: pr["deletions"] as? Int ?? 0, files: pr["changedFiles"] as? Int ?? 0,
                     comments: (pr["comments"] as? [String: Any])?["totalCount"] as? Int ?? 0, review: pr["reviewDecision"] as? String,
                     checks: CIRing(steps: steps), checkLinks: links, runIDs: runIDs,
                     labels: ((pr["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                     mergeable: (pr["mergeable"] as? String).map { $0 == "MERGEABLE" },
                     updated: (pr["updatedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) } ?? Date())
    }

    // MARK: - Lists

    private static func search(_ q: String, wantsReview: Bool = false) async throws -> [GitHubAnswer.Item] {
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let query = """
        query { search(query: "\(escaped)", type: ISSUE, first: 12) { nodes {
          ... on PullRequest { __typename number title url state isDraft updatedAt author { login } comments { totalCount }
            repository { nameWithOwner } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }
          ... on Issue { __typename number title url state updatedAt author { login } comments { totalCount } repository { nameWithOwner } } } } }
        """
        guard let result = try await graphQL(query), let nodes = (result["search"] as? [String: Any])?["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { n in
            guard let number = n["number"] as? Int, let url = (n["url"] as? String).flatMap(URL.init(string:)),
                  let repo = (n["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
            let isPull = n["__typename"] as? String == "PullRequest"
            let raw = n["state"] as? String
            let state: GitHubAnswer.Pull.State = raw == "MERGED" ? .merged : raw == "CLOSED" ? .closed : (n["isDraft"] as? Bool ?? false) ? .draft : .open
            let commit = (((n["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"]) as? [String: Any]
            let checks: GitHubService.PullRequest.Checks = switch (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String {
            case "SUCCESS": .passed
            case "FAILURE", "ERROR": .failed
            case "PENDING", "EXPECTED": .pending
            default: .none
            }
            return .init(repo: repo, number: number, title: n["title"] as? String ?? "", url: url, isPull: isPull, state: state,
                         checks: checks, wantsReview: wantsReview, author: (n["author"] as? [String: Any])?["login"] as? String ?? "",
                         comments: (n["comments"] as? [String: Any])?["totalCount"] as? Int ?? 0,
                         updated: (n["updatedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) } ?? Date())
        }
    }

    /// The latest runs in the repos you're working in, newest first; followed ones carry their ring.
    private static func recentRuns() async throws -> [GitHubAnswer.Run] {
        let github = GitHubService.shared
        var out: [GitHubAnswer.Run] = []
        for repo in github.knownRepos.prefix(4) {
            guard let json = try? await github.get("/repos/\(repo)/actions/runs?per_page=6") as? [String: Any],
                  let runs = json["workflow_runs"] as? [[String: Any]] else { continue }
            for r in runs {
                guard let id = r["id"] as? Int, let url = (r["html_url"] as? String).flatMap(URL.init(string:)) else { continue }
                let sha = r["head_sha"] as? String ?? ""
                let started = (r["run_started_at"] as? String ?? r["created_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) } ?? Date()
                let state = CIStepState(status: r["status"] as? String, conclusion: r["conclusion"] as? String)
                out.append(.init(id: id, repo: repo, workflow: r["name"] as? String ?? "Workflow", title: r["display_title"] as? String ?? "",
                                 branch: r["head_branch"] as? String ?? "", event: r["event"] as? String ?? "", state: state, url: url,
                                 started: started,
                                 ended: state.isDone ? (r["updated_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) } : nil,
                                 ring: github.runs.first { $0.repo == repo && $0.sha == sha }?.ring))
            }
        }
        return Array(out.sorted { $0.started > $1.started }.prefix(10))
    }

    private static func graphQL(_ query: String) async throws -> [String: Any]? {
        let body = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, response) = try await GitHubService.shared.request("/graphql", method: "POST", body: body)
        guard response.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "GitHub answered \(response.statusCode).")
        }
        if json["data"] == nil, let errors = json["errors"] as? [[String: Any]], let first = errors.first?["message"] as? String {
            throw Failure(message: first)
        }
        return json["data"] as? [String: Any]
    }

    /// Re-runs a pull request's failed Actions jobs.
    static func rerunFailed(_ pull: GitHubAnswer.Pull) async -> Bool {
        var ok = false
        for id in pull.runIDs {
            if let (_, r) = try? await GitHubService.shared.request("/repos/\(pull.repo)/actions/runs/\(id)/rerun-failed-jobs", method: "POST"),
               (200..<300).contains(r.statusCode) { ok = true }
        }
        return ok
    }
}
