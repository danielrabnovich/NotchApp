import AppKit
import Combine

/// Your local git repos at a glance: which have changes not committed, commits not pushed, or a
/// branch that was never pushed. Found by themselves, from where your coding agents have worked
/// lately (each Claude Code and Codex transcript starts with its folder), so there's nothing to set
/// up. Read with `git status` while the Home card shows, and never with locks an agent could trip on.
@MainActor
final class RepoMonitor: ObservableObject {
    static let shared = RepoMonitor()

    struct Repo: Identifiable, Equatable {
        /// The working tree's folder.
        let path: String
        let name: String
        let branch: String?
        /// Its upstream ("origin/main"); nil when the branch was never pushed.
        let upstream: String?
        let ahead: Int
        let behind: Int
        /// Files changed, staged or not, and new ones.
        let changed: Int
        /// An agent's extra worktree rather than the repo's main folder.
        let worktree: Bool
        /// When an agent last worked here.
        let active: Date

        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
        /// Work that's only on this Mac: changes, unpushed commits, or a branch with no upstream.
        var unshared: Bool { changed > 0 || ahead > 0 || (upstream == nil && branch != nil) }
        var clean: Bool { !unshared && behind == 0 }

        /// "3 changed · 2 to push", "1 behind", "up to date".
        var summary: String {
            var parts: [String] = []
            if changed > 0 { parts.append("\(changed) changed") }
            if ahead > 0 { parts.append("\(ahead) to push") }
            if upstream == nil, branch != nil, ahead == 0 { parts.append("not pushed") }
            if behind > 0 { parts.append("\(behind) behind") }
            return parts.isEmpty ? "Up to date" : parts.joined(separator: " · ")
        }
    }

    @Published private(set) var repos: [Repo] = []
    @Published private(set) var loading = false

    /// The ones with something on this Mac that isn't anywhere else, first.
    var needingAttention: [Repo] { repos.filter(\.unshared) }

    private var viewers = 0
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// How far back an agent's folder still counts as one you're working in.
    nonisolated static let window: TimeInterval = 14 * 86400
    nonisolated static let git = ["/usr/bin/git", "/opt/homebrew/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }

    func start() {
        AppSettings.shared.$reposEnabled.removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async {
                if on { self?.refresh() } else { self?.repos = [] }
            }
        }.store(in: &cancellables)
    }

    /// The Home card is showing: keep it fresh (every 30 s), and stop when it goes.
    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        refresh()
        let t = Timer(timeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { RepoMonitor.shared.refresh() } }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard AppSettings.shared.reposEnabled, !loading, let git = Self.git else { return }
        loading = true
        Task.detached(priority: .utility) {
            let found = Self.discover().compactMap { Self.status(of: $0.path, active: $0.active, git: git) }
            let repos = Self.ordered(Self.dedupe(found))
            await MainActor.run {
                let monitor = RepoMonitor.shared
                monitor.loading = false
                if monitor.repos != repos { monitor.repos = repos }
            }
        }
    }

    // MARK: - Actions

    func reveal(_ repo: Repo) { NSWorkspace.shared.activateFileViewerSelecting([repo.url]) }

    func openInTerminal(_ repo: Repo) {
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        guard let terminal else { return }
        NSWorkspace.shared.open([repo.url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func copyPath(_ repo: Repo) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(repo.path, forType: .string)
    }

    // MARK: - Finding them

    /// Folders agents worked in lately, newest first: the `cwd` near the top of each Claude Code
    /// transcript (~/.claude/projects/*/*.jsonl) and Codex session (~/.codex/sessions/**).
    nonisolated static func discover() -> [(path: String, active: Date)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let since = Date().addingTimeInterval(-window)
        var latest: [String: Date] = [:]

        func consider(_ file: URL, modified: Date) {
            guard modified > since, let cwd = cwd(in: file) else { return }
            if modified > latest[cwd] ?? .distantPast { latest[cwd] = modified }
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let claude = home.appendingPathComponent(".claude/projects")
        for folder in (try? fm.contentsOfDirectory(at: claude, includingPropertiesForKeys: nil)) ?? [] {
            // Each project's newest transcript is enough to know where it was.
            let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url in (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate).map { (url, $0) } }
            if let newest = files.max(by: { $0.1 < $1.1 }) { consider(newest.0, modified: newest.1) }
        }
        let codex = home.appendingPathComponent(".codex/sessions")
        if let walker = fm.enumerator(at: codex, includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                if let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate { consider(url, modified: modified) }
            }
        }
        return latest
            // Scratch folders and ones since deleted aren't repos to keep an eye on.
            .filter { !$0.key.hasPrefix("/private/") && !$0.key.hasPrefix("/tmp/") && fm.fileExists(atPath: $0.key) }
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    /// The first `"cwd":"…"` in the file's opening stretch.
    nonisolated static func cwd(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32_768), let text = String(data: data, encoding: .utf8) else { return nil }
        return firstCwd(in: text)
    }

    nonisolated static func firstCwd(in text: String) -> String? {
        guard let key = text.range(of: #""cwd":""#) else { return nil }
        let rest = text[key.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let path = rest[..<end].replacingOccurrences(of: "\\/", with: "/")
        return path.hasPrefix("/") ? path : nil
    }

    // MARK: - Reading one

    /// Where a folder's repo stands, from one `git status`; nil if it isn't in a repo.
    nonisolated static func status(of folder: String, active: Date, git: String) -> Repo? {
        // No optional locks: an agent committing in the same repo never finds index.lock taken by us.
        let result = Shell.runSync(git, ["--no-optional-locks", "-C", folder, "status", "--porcelain=v2", "--branch", "--show-stash"], timeout: 10)
        guard result.ok else { return nil }
        let top = Shell.runSync(git, ["-C", folder, "rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir"], timeout: 5)
        let lines = top.out.split(separator: "\n").map(String.init)
        guard let root = lines.first, !root.isEmpty else { return nil }
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        let gitDir = lines.count >= 2 ? URL(fileURLWithPath: lines[1], relativeTo: base).standardized : nil
        let common = lines.count >= 3 ? URL(fileURLWithPath: lines[2], relativeTo: base).standardized : nil
        let worktree = gitDir != nil && common != nil && gitDir?.path != common?.path
        // An extra worktree goes by its repo too: "shop › fix-login".
        let repoName = common.map { $0.lastPathComponent == ".git" ? $0.deletingLastPathComponent().lastPathComponent : $0.lastPathComponent }
        let name = worktree ? "\(repoName ?? "") › \(URL(fileURLWithPath: root).lastPathComponent)" : nil
        return parse(result.out, path: root, worktree: worktree, active: active, name: name)
    }

    /// `git status --porcelain=v2 --branch`: the branch headers, then a line per changed file.
    nonisolated static func parse(_ output: String, path: String, worktree: Bool, active: Date, name: String? = nil) -> Repo {
        var branch: String?, upstream: String?, ahead = 0, behind = 0, changed = 0
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") {
                changed += 1
            }
        }
        return Repo(path: path, name: name ?? URL(fileURLWithPath: path).lastPathComponent, branch: branch, upstream: upstream,
                    ahead: ahead, behind: behind, changed: changed, worktree: worktree, active: active)
    }

    /// One row per working tree; agents' extra worktrees only while they hold work not pushed.
    nonisolated static func dedupe(_ repos: [Repo]) -> [Repo] {
        var seen = Set<String>()
        return repos.filter { repo in
            guard seen.insert(repo.path).inserted else { return false }
            return !repo.worktree || repo.unshared
        }
    }

    /// Work only on this Mac first, then the rest; most recently worked in first within each.
    nonisolated static func ordered(_ repos: [Repo]) -> [Repo] {
        repos.sorted { ($0.unshared ? 0 : 1, -$0.active.timeIntervalSince1970) < ($1.unshared ? 0 : 1, -$1.active.timeIntervalSince1970) }
    }
}
