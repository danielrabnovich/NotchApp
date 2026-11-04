import Foundation
import NotchKit
import Testing

struct GitHubModelTests {
    @Test("Step states", arguments: [
        (String?("completed"), String?("success"), CIStepState.success), ("completed", "failure", .failure), ("completed", "timed_out", .failure),
        ("completed", "skipped", .skipped), ("completed", "cancelled", .cancelled), ("completed", "neutral", .success),
        ("in_progress", nil, .running), ("queued", nil, .queued), ("waiting", nil, .queued), (String?.none, String?.none, .queued),
    ])
    func states(status: String?, conclusion: String?, expected: CIStepState) {
        #expect(CIStepState(status: status, conclusion: conclusion) == expected)
    }

    @Test func ringRunning() {
        let ring = CIRing(jobs: [
            .init(name: "Build", status: "in_progress", conclusion: nil, steps: [
                ("Checkout", "completed", "success"), ("Compile", "in_progress", nil), ("Upload", "queued", nil),
            ]),
            .init(name: "Lint", status: "queued", conclusion: nil, steps: []),
        ])
        #expect(ring.total == 4)
        #expect(ring.done == 1)
        #expect(ring.outcome == .running)
        #expect(ring.current?.name == "Compile")
    }

    @Test func jobsLikeGitHubCountsThem() {
        let ring = CIRing(jobs: [
            .init(name: "Test", status: "completed", conclusion: "success", steps: [("Checkout", "completed", "success"), ("Run", "completed", "success")]),
            .init(name: "Build", status: "in_progress", conclusion: nil, steps: [("Checkout", "completed", "success"), ("Build", "in_progress", nil)]),
        ])
        #expect(ring.jobsTotal == 2)
        #expect(ring.jobsDone == 1)
        #expect(ring.jobs.map(\.state) == [.success, .running])
        #expect(ring.total == 4)
    }

    @Test func ringFailedLeavesNoStepWaiting() {
        let ring = CIRing(jobs: [
            .init(name: "Test", status: "completed", conclusion: "failure", steps: [
                ("Checkout", "completed", "success"), ("Run tests", "completed", "failure"), ("Report", "queued", nil),
            ]),
        ])
        #expect(ring.steps.map(\.state) == [.success, .failure, .skipped])
        #expect(ring.outcome == .failed)
        #expect(ring.current?.name == "Run tests")
    }

    @Test func failureWhileOthersRun() {
        let ring = CIRing(jobs: [
            .init(name: "A", status: "completed", conclusion: "failure", steps: [("x", "completed", "failure")]),
            .init(name: "B", status: "in_progress", conclusion: nil, steps: [("y", "in_progress", nil)]),
        ])
        #expect(ring.outcome == .running)
        #expect(ring.hasFailure)
    }

    @Test func passed() {
        let ring = CIRing(jobs: [.init(name: "A", status: "completed", conclusion: "success", steps: [("x", "completed", "success"), ("y", "completed", "skipped")])])
        #expect(ring.outcome == .passed)
        #expect(ring.fraction == 1)
    }

    @Test func emptyIsRunning() {
        #expect(CIRing(jobs: []).outcome == .running)
    }

    /// The checks box from a real PR: 7 in progress, 1 skipped, 3 successful.
    @Test func checksLikeGitHub() {
        func job(_ name: String, _ status: String, _ conclusion: String?) -> CIRing.Job {
            .init(name: name, status: status, conclusion: conclusion, steps: [])
        }
        let ring = CIRing(jobs: (1...7).map { job("CI / j\($0) (push)", "in_progress", nil) }
                          + [job("CI / docs (push)", "completed", "skipped")]
                          + (1...3).map { job("CI / ok\($0) (pull_request)", "completed", "success") })
        #expect(ring.checksSummary == "7 in progress, 1 skipped, 3 successful checks")
        #expect(ring.checksHeadline == "Some checks haven't completed yet")
        #expect(ring.arcs.map(\.state) == [.success, .skipped, .running])
        #expect(ring.arcs.map(\.count) == [3, 1, 7])
    }

    @Test func checksHeadlines() {
        let passed = CIRing(jobs: [.init(name: "a", status: "completed", conclusion: "success", steps: []),
                                   .init(name: "b", status: "completed", conclusion: "skipped", steps: [])])
        #expect(passed.checksHeadline == "All checks have passed")
        let failed = CIRing(jobs: [.init(name: "a", status: "completed", conclusion: "failure", steps: []),
                                   .init(name: "b", status: "completed", conclusion: "success", steps: [])])
        #expect(failed.checksHeadline == "Some checks were not successful")
        #expect(failed.checksSummary == "1 failing, 1 successful checks")
        #expect(CIRing(jobs: [.init(name: "a", status: "queued", conclusion: nil, steps: [])]).checksSummary == "1 queued check")
    }

    @Test func startedJobWithWaitingStepsIsRunning() {
        let ring = CIRing(jobs: [.init(name: "a", status: "in_progress", conclusion: nil, steps: [("x", "queued", nil), ("y", "queued", nil)])])
        #expect(ring.jobs.first?.state == .running)
    }

    @Test("Check names", arguments: [
        (String?("CI"), "kernel", String?("pull_request"), "CI / kernel (pull_request)"),
        ("CI", "ts", "push", "CI / ts (push)"),
        (nil, "Vercel", nil, "Vercel"),
    ])
    func checkNames(workflow: String?, job: String, event: String?, expected: String) {
        #expect(GitHubLinks.checkName(workflow: workflow, job: job, event: event) == expected)
    }

    @Test("Web links", arguments: [
        ("https://api.github.com/repos/o/r/pulls/12", "https://github.com/o/r/pull/12"),
        ("https://api.github.com/repos/o/r/issues/7", "https://github.com/o/r/issues/7"),
        ("https://api.github.com/repos/o/r/commits/abc", "https://github.com/o/r/commit/abc"),
        ("https://api.github.com/repos/o/r/check-suites/1", "https://github.com/o/r"),
    ])
    func web(api: String, expected: String) {
        #expect(GitHubLinks.web(api: api, repo: "o/r").absoluteString == expected)
    }

    @Test("Remotes", arguments: [
        ("https://github.com/o/r.git", "o/r"), ("git@github.com:o/r.git", "o/r"), ("ssh://git@github.com/o/r", "o/r"),
        ("https://github.com/o/r/", "o/r"), ("https://gitlab.com/o/r.git", nil),
    ])
    func remotes(remote: String, expected: String?) {
        #expect(GitHubLinks.repo(remote: remote) == expected)
    }

    @Test func reflog() {
        let new = String(repeating: "b", count: 40), old = String(repeating: "a", count: 40)
        #expect(GitHubLinks.pushedSHA(reflogLine: "\(old) \(new) Phil <p@x> 1700000000 +0000\tupdate by push") == new)
        #expect(GitHubLinks.pushedSHA(reflogLine: "\(old) \(new) Phil <p@x> 1700000000 +0000\tfetch: fast-forward") == nil)
        #expect(GitHubLinks.pushedSHA(reflogLine: "\(old) \(String(repeating: "0", count: 40)) P <p> 1 +0000\tupdate by push") == nil)
    }

    @Test func loudness() {
        #expect(GitHubReason(api: "review_requested").loudness == .waitingOnYou)
        #expect(GitHubReason(api: "mention").needsYou)
        #expect(!GitHubReason(api: "comment").needsYou)
        #expect(GitHubReason(api: "something_new") == .other)
    }
}

struct GitHubQueryTests {
    @Test("Parses", arguments: [
        ("pr 142", GitHubQuery.pull(repo: nil, number: 142)), ("PR #7", .pull(repo: nil, number: 7)), ("#12", .pull(repo: nil, number: 12)),
        ("pull request 3", .pull(repo: nil, number: 3)), ("danielrabnovich/NotchApp#3", .pull(repo: "danielrabnovich/NotchApp", number: 3)),
        ("https://github.com/o/r/pull/55/files", .pull(repo: "o/r", number: 55)),
        ("my prs", .mine), ("Pull requests", .mine), ("reviews", .reviews), ("what needs my review?", .reviews),
        ("ci", .runs), ("Actions", .runs), ("mentions", .mentions),
        ("prs glass edge", .search(text: "glass edge", pulls: true)), ("issues about crash", .search(text: "crash", pulls: false)),
        ("gh notch", .search(text: "notch", pulls: true)),
    ])
    func parses(query: String, expected: GitHubQuery) {
        #expect(GitHubQuery.parse(query) == expected)
    }

    @Test("Leaves other searches alone", arguments: [
        "what is ci/cd", "weather tomorrow", "pricing page", "the pr deck I sent", "print to pdf", "show me prices",
    ])
    func leaves(query: String) {
        #expect(GitHubQuery.parse(query) == nil)
    }
}
