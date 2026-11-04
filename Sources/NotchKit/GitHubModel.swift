import Foundation

/// A GitHub Actions step (or a job with no steps yet), as the CI ring draws it: one segment each,
/// green when it passed, yellow while it runs, red when it failed, grey while it waits.
public enum CIStepState: String, Equatable, Sendable {
    case queued, running, success, failure, skipped, cancelled

    /// From the API's `status` and `conclusion` for a job or a step.
    public init(status: String?, conclusion: String?) {
        switch status {
        case "completed":
            switch conclusion {
            case "success", "neutral": self = .success
            case "skipped": self = .skipped
            case "cancelled": self = .cancelled
            default: self = .failure // failure, timed_out, action_required, startup_failure, stale
            }
        case "in_progress": self = .running
        default: self = .queued // queued, waiting, requested, pending
        }
    }

    public var isDone: Bool { self != .queued && self != .running }
}

/// Every step of every job for one commit, in order, and what they add up to.
public struct CIRing: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let job: String
        public let name: String
        public let state: CIStepState
        public init(job: String, name: String, state: CIStepState) {
            self.job = job
            self.name = name
            self.state = state
        }
    }

    public enum Outcome: Equatable, Sendable { case running, passed, failed, cancelled }

    public var steps: [Step]

    public init(steps: [Step]) { self.steps = steps }

    /// A job's steps; a job that hasn't started (no steps listed yet) stands as one step of its own.
    public struct Job: Sendable {
        public let name: String
        public let status: String?
        public let conclusion: String?
        public let steps: [(name: String, status: String?, conclusion: String?)]
        public init(name: String, status: String?, conclusion: String?, steps: [(name: String, status: String?, conclusion: String?)]) {
            self.name = name
            self.status = status
            self.conclusion = conclusion
            self.steps = steps
        }
    }

    public init(jobs: [Job]) {
        steps = jobs.flatMap { job -> [Step] in
            guard !job.steps.isEmpty else {
                return [Step(job: job.name, name: job.name, state: CIStepState(status: job.status, conclusion: job.conclusion))]
            }
            let jobState = CIStepState(status: job.status, conclusion: job.conclusion)
            var out = job.steps.map { s in
                var state = CIStepState(status: s.status, conclusion: s.conclusion)
                // A cancelled or failed job leaves its later steps "queued" forever: they won't run.
                if jobState.isDone, !state.isDone { state = .skipped }
                return Step(job: job.name, name: s.name, state: state)
            }
            // A job that has started but lists only waiting steps is running, as GitHub says.
            if jobState == .running, let first = out.firstIndex(where: { $0.state == .queued }),
               !out.contains(where: { $0.state == .running }) {
                out[first] = Step(job: job.name, name: out[first].name, state: .running)
            }
            return out
        }
    }

    /// The steps grouped by job, in order: what GitHub lists as checks.
    public struct JobGroup: Equatable, Sendable {
        public let name: String
        public let steps: [Step]
        /// The job as a whole: failed as soon as a step fails, done when every step is.
        public var state: CIStepState {
            if steps.contains(where: { $0.state == .failure }) { return .failure }
            if steps.allSatisfy({ $0.state.isDone }) {
                if steps.contains(where: { $0.state == .cancelled }) { return .cancelled }
                return steps.allSatisfy { $0.state == .skipped } ? .skipped : .success
            }
            return steps.contains(where: { $0.state != .queued }) ? .running : .queued
        }
    }

    public var jobs: [JobGroup] {
        var out: [JobGroup] = []
        for step in steps {
            if let last = out.last, last.name == step.job {
                out[out.count - 1] = JobGroup(name: last.name, steps: last.steps + [step])
            } else {
                out.append(JobGroup(name: step.job, steps: [step]))
            }
        }
        return out
    }

    /// Jobs finished, and how many there are: the count GitHub shows ("1 of 2 checks").
    public var jobsDone: Int { jobs.filter { $0.state.isDone }.count }
    public var jobsTotal: Int { jobs.count }

    public var done: Int { steps.filter { $0.state.isDone }.count }
    public var total: Int { steps.count }
    /// How far along it is, 0…1.
    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    public var outcome: Outcome {
        if steps.contains(where: { $0.state == .failure }) && steps.allSatisfy({ $0.state.isDone }) { return .failed }
        if steps.isEmpty || steps.contains(where: { !$0.state.isDone }) { return .running }
        if steps.contains(where: { $0.state == .cancelled }) { return .cancelled }
        return .passed
    }

    // MARK: As GitHub's checks box says it

    /// How many checks are in each state, in the order GitHub's donut draws them clockwise from the
    /// top: successful, skipped, cancelled, failing, in progress, queued. Empty states are left out.
    public var arcs: [(state: CIStepState, count: Int)] {
        let order: [CIStepState] = [.success, .skipped, .cancelled, .failure, .running, .queued]
        let states = jobs.map(\.state)
        return order.map { state in (state, states.filter { $0 == state }.count) }.filter { $0.count > 0 }
    }

    /// "7 in progress, 1 skipped, 3 successful checks", worded and ordered as GitHub does.
    public var checksSummary: String {
        guard jobsTotal > 0 else { return "Waiting for checks" }
        let words: [(CIStepState, String)] = [(.failure, "failing"), (.cancelled, "cancelled"), (.running, "in progress"),
                                              (.queued, "queued"), (.skipped, "skipped"), (.success, "successful")]
        let states = jobs.map(\.state)
        let parts = words.compactMap { state, word -> String? in
            let n = states.filter { $0 == state }.count
            return n > 0 ? "\(n) \(word)" : nil
        }
        return parts.joined(separator: ", ") + (jobsTotal == 1 ? " check" : " checks")
    }

    /// GitHub's headline over the checks: "Some checks haven't completed yet", "All checks have passed".
    public var checksHeadline: String {
        let states = jobs.map(\.state)
        if states.isEmpty { return "Checks are starting" }
        if states.contains(where: { !$0.isDone }) { return "Some checks haven't completed yet" }
        if states.allSatisfy({ $0 == .failure }) { return "All checks have failed" }
        if states.contains(where: { $0 == .failure || $0 == .cancelled }) { return "Some checks were not successful" }
        return "All checks have passed"
    }

    /// Something already failed, though other steps may still be going: worth saying early.
    public var hasFailure: Bool { steps.contains { $0.state == .failure } }

    /// The step running now, or the first that failed: "Build › Run tests".
    public var current: Step? {
        steps.first { $0.state == .failure } ?? steps.first { $0.state == .running } ?? steps.first { $0.state == .queued }
    }
}

/// Why a GitHub notification arrived, and how loudly the notch says it.
public enum GitHubReason: String, Sendable {
    case reviewRequested = "review_requested"
    case mention, teamMention = "team_mention", assign, author, comment, stateChange = "state_change"
    case ciActivity = "ci_activity", securityAlert = "security_alert", manual, subscribed, invitation
    case approvalRequested = "approval_requested", memberFeatureRequested = "member_feature_requested"
    case other

    public init(api: String) { self = GitHubReason(rawValue: api) ?? .other }

    public enum Loudness: Int, Comparable, Sendable {
        /// Not shown.
        case quiet
        /// A Banner, only when every update is wanted.
        case update
        /// A Banner: it's about you.
        case aboutYou
        /// A Prompt: it's waiting on you.
        case waitingOnYou
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public var loudness: Loudness {
        switch self {
        case .reviewRequested, .approvalRequested: .waitingOnYou
        case .mention, .teamMention, .assign, .securityAlert: .aboutYou
        case .comment, .author, .stateChange, .ciActivity, .manual, .invitation: .update
        case .subscribed, .memberFeatureRequested, .other: .quiet
        }
    }

    /// Counts towards the Glance's "needs you" number.
    public var needsYou: Bool { loudness >= .aboutYou }
}

public enum GitHubLinks {
    /// A check's name as GitHub lists it: "CI / kernel (pull_request)". A check run that isn't from
    /// a workflow (an app's) has just its own name.
    public static func checkName(workflow: String?, job: String, event: String?) -> String {
        guard let workflow, !workflow.isEmpty else { return job }
        return "\(workflow) / \(job)" + (event.map { " (\($0))" } ?? "")
    }

    /// The web page for an API address: …/repos/o/r/pulls/12 → github.com/o/r/pull/12.
    public static func web(api: String?, repo: String) -> URL {
        let base = "https://github.com/\(repo)"
        guard let api, let range = api.range(of: "/repos/\(repo)/") else { return URL(string: base)! }
        let rest = api[range.upperBound...].split(separator: "/").map(String.init)
        switch (rest.first, rest.count) {
        case ("pulls", 2): return URL(string: "\(base)/pull/\(rest[1])")!
        case ("issues", 2): return URL(string: "\(base)/issues/\(rest[1])")!
        case ("commits", 2): return URL(string: "\(base)/commit/\(rest[1])")!
        case ("releases", 2): return URL(string: "\(base)/releases")!
        case ("discussions", 2): return URL(string: "\(base)/discussions/\(rest[1])")!
        default: return URL(string: base)!
        }
    }

    /// "owner/repo" from a remote: https://github.com/o/r.git, git@github.com:o/r.git, ssh://git@github.com/o/r.
    public static func repo(remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = s.range(of: "github.com") else { return nil }
        s = String(s[host.upperBound...])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        if s.hasSuffix(".git") { s.removeLast(4) }
        if s.hasSuffix("/") { s.removeLast() }
        let parts = s.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// A pushed ref from a reflog line: "<old> <new> Name <email> 1700000000 +0000\tupdate by push".
    /// Nil for anything else (a fetch moving the remote branch, a deletion).
    public static func pushedSHA(reflogLine line: String) -> String? {
        let fields = line.split(separator: "\t", maxSplits: 1)
        guard fields.count == 2, fields[1].hasPrefix("update by push") else { return nil }
        let shas = fields[0].split(separator: " ")
        guard shas.count >= 2, shas[1].count == 40, shas[1] != String(repeating: "0", count: 40) else { return nil }
        return String(shas[1])
    }
}

/// What a search-bar query asks of GitHub, when it plainly does: "pr 142", "owner/repo#12", a pull
/// request's link, "my prs", "reviews", "ci", "issues glass". Anything else is left to Search.
public enum GitHubQuery: Equatable, Sendable {
    /// A pull request by number; `repo` nil when the number came alone ("pr 142", "#142").
    case pull(repo: String?, number: Int)
    case mine
    case reviews
    case runs
    case mentions
    /// Search pull requests (`pulls`) or issues, involving you, for text.
    case search(text: String, pulls: Bool)

    public static func parse(_ raw: String) -> GitHubQuery? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = q.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?!."))
        guard !lower.isEmpty else { return nil }

        // A link to a pull request.
        if let m = match(#"github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)"#, q), let n = Int(m[2]) { return .pull(repo: m[1], number: n) }
        // owner/repo#12
        if let m = match(#"^([\w.-]+/[\w.-]+)#(\d+)$"#, q), let n = Int(m[2]) { return .pull(repo: m[1], number: n) }
        // pr 142, pr #142, pull 142, pull request 142, #142
        if let m = match(#"^(?:prs?|pull(?: request)?)\s*#?(\d+)$|^#(\d+)$"#, lower),
           let n = Int(m[1].isEmpty ? m[2] : m[1]) { return .pull(repo: nil, number: n) }

        let mine: Set<String> = ["prs", "my prs", "my pr", "pull requests", "my pull requests", "open prs", "my open prs",
                                 "my open pull requests", "gh prs", "github prs", "pr status", "my pr status"]
        if mine.contains(lower) { return .mine }
        let reviews: Set<String> = ["reviews", "review requests", "to review", "prs to review", "my reviews", "needs review",
                                    "needs my review", "what needs my review", "waiting for my review", "review queue"]
        if reviews.contains(lower) || lower.contains("need my review") || lower.contains("needs my review") { return .reviews }
        let runs: Set<String> = ["ci", "ci status", "actions", "github actions", "builds", "my builds", "checks", "workflow runs",
                                 "runs", "gh runs", "build status", "is ci passing", "did ci pass", "is the build passing"]
        if runs.contains(lower) { return .runs }
        let mentions: Set<String> = ["mentions", "my mentions", "github notifications", "gh notifications", "gh inbox", "github inbox"]
        if mentions.contains(lower) { return .mentions }

        // "pr glass edge", "prs about glass", "issues crash", "gh notch"
        if let m = match(#"^(prs?|pull requests?|issues?|gh|github)\s+(?:about\s+|for\s+|with\s+)?(.+)$"#, lower) {
            let text = m[2].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return .search(text: text, pulls: !m[1].hasPrefix("issue"))
        }
        return nil
    }

    /// The groups of the first match (the whole match first, "" for a group that didn't take part).
    private static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}
