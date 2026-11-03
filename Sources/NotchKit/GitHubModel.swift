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
            return job.steps.map { s in
                var state = CIStepState(status: s.status, conclusion: s.conclusion)
                // A cancelled or failed job leaves its later steps "queued" forever: they won't run.
                if jobState.isDone, !state.isDone { state = .skipped }
                return Step(job: job.name, name: s.name, state: state)
            }
        }
    }

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
