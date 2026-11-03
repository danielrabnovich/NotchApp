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
