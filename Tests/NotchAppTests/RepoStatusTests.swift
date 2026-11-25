import Foundation
import Testing
@testable import NotchApp

/// Reading `git status --porcelain=v2 --branch` and agents' transcripts for the Repos card.
@MainActor
struct RepoStatusTests {
    private let now = Date()

    @Test func changesAndCommitsToPush() {
        let out = """
        # branch.oid 0123abcd
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        # stash 1
        1 .M N... 100644 100644 100644 aaaa bbbb Sources/App.swift
        1 A. N... 000000 100644 100644 0000 cccc Sources/New.swift
        ? notes.txt
        """
        let repo = RepoMonitor.parse(out, path: "/Users/me/Code/shop", worktree: false, active: now)
        #expect(repo.name == "shop")
        #expect(repo.branch == "main")
        #expect(repo.upstream == "origin/main")
        #expect(repo.ahead == 2)
        #expect(repo.behind == 1)
        #expect(repo.changed == 3) // the stash header isn't a file
        #expect(repo.unshared)
        #expect(repo.summary == "3 changed · 2 to push · 1 behind")
    }

    @Test func cleanAndUpToDate() {
        let out = "# branch.oid 0123\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +0 -0\n"
        let repo = RepoMonitor.parse(out, path: "/r/app", worktree: false, active: now)
        #expect(repo.clean)
        #expect(!repo.unshared)
        #expect(repo.summary == "Up to date")
    }

    @Test func aBranchNeverPushedIsWorkOnlyHere() {
        let out = "# branch.oid 0123\n# branch.head fix-login\n"
        let repo = RepoMonitor.parse(out, path: "/r/app", worktree: true, active: now, name: "app › fix-login")
        #expect(repo.upstream == nil)
        #expect(repo.unshared)
        #expect(repo.summary == "not pushed")
        #expect(repo.name == "app › fix-login")
    }

    @Test func detachedHeadIsNotAnUnpushedBranch() {
        let repo = RepoMonitor.parse("# branch.oid 0123\n# branch.head (detached)\n", path: "/r/app", worktree: false, active: now)
        #expect(repo.branch == nil)
        #expect(!repo.unshared)
    }

    @Test func cleanWorktreesAreDropped() {
        let clean = RepoMonitor.parse("# branch.head a\n# branch.upstream origin/a\n# branch.ab +0 -0\n", path: "/w/1", worktree: true, active: now)
        let dirty = RepoMonitor.parse("# branch.head b\n# branch.upstream origin/b\n# branch.ab +0 -0\n? x\n", path: "/w/2", worktree: true, active: now)
        let main = RepoMonitor.parse("# branch.head main\n# branch.upstream origin/main\n# branch.ab +0 -0\n", path: "/r", worktree: false, active: now)
        #expect(RepoMonitor.dedupe([clean, dirty, main, main]).map(\.path) == ["/w/2", "/r"])
    }

    @Test func workOnlyHereComesFirst() {
        let older = RepoMonitor.parse("# branch.head a\n? x\n", path: "/old", worktree: false, active: now.addingTimeInterval(-3600))
        let newer = RepoMonitor.parse("# branch.head main\n# branch.upstream o/main\n# branch.ab +0 -0\n", path: "/new", worktree: false, active: now)
        #expect(RepoMonitor.ordered([newer, older]).map(\.path) == ["/old", "/new"])
    }

    @Test func transcriptsGiveTheirFolder() {
        let head = #"{"type":"mode"}"# + "\n" + #"{"parentUuid":null,"cwd":"/Users/me/Code/shop","sessionId":"x"}"#
        #expect(RepoMonitor.firstCwd(in: head) == "/Users/me/Code/shop")
        #expect(RepoMonitor.firstCwd(in: #"{"cwd":"\/Users\/me\/a"}"#) == "/Users/me/a")
        #expect(RepoMonitor.firstCwd(in: #"{"type":"mode"}"#) == nil)
    }
}
