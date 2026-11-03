import AppKit
import NotchKit

/// Vercel deployments for Search.
struct DeploysAnswer: Equatable {
    var headline: String
    var detail: String?
    var deployments: [VercelService.Deployment]
    var links: [URL] { deployments.compactMap { $0.url ?? $0.inspector } }
}

/// Linear issues for Search: one in full, or a list.
struct LinearAnswer: Equatable {
    var headline: String
    var detail: String?
    var issue: LinearService.Issue?
    var issues: [LinearService.Issue] = []
    var links: [URL] { issue.map { [$0.url] } ?? issues.map(\.url) }
}

/// Which developer service a search-bar query is for, and its answer.
@MainActor
enum DevSearch {
    static func route(for query: String) -> AssistantStore.Route? {
        if GitHubSearch.understands(query) { return .github }
        switch DevQuery.parse(query) {
        case .linearIssue?, .linearMine?, .linearSearch?:
            return AppSettings.shared.linearEnabled && LinearService.shared.connection.user != nil ? .linear : nil
        case .deploys?:
            return AppSettings.shared.vercelEnabled && VercelService.shared.connection.user != nil ? .deploys : nil
        case nil:
            return nil
        }
    }

    static func deploys(_ query: String) async throws -> DeploysAnswer {
        let vercel = VercelService.shared
        guard vercel.connection.user != nil else { throw DevAPI.Failure(message: "Sign in to Vercel in Settings › Developer.") }
        guard case let .deploys(project)? = DevQuery.parse(query) else { throw DevAPI.Failure(message: "Not a Vercel search.") }
        // Following builds as they happen keeps this list fresh; the followed ones are newest.
        let live = vercel.followed.flatMap(\.deployments)
        var list = vercel.recent.map { d in live.first { $0.id == d.id } ?? d }
        if let project { list = list.filter { $0.project.lowercased().contains(project) } }
        let building = list.filter { !$0.isDone }.count, failed = list.prefix(10).filter { $0.state == .error }.count
        return DeploysAnswer(headline: project.map { "Deployments of \($0)" } ?? "Recent deployments",
                             detail: list.isEmpty ? "None found" : [building > 0 ? "\(building) building" : nil, failed > 0 ? "\(failed) failed" : nil,
                                                                    "\(min(list.count, 12)) recent"].compactMap { $0 }.joined(separator: " · "),
                             deployments: Array(list.prefix(12)))
    }

    static func linear(_ query: String) async throws -> LinearAnswer {
        let linear = LinearService.shared
        guard linear.connection.user != nil else { throw DevAPI.Failure(message: "Sign in to Linear in Settings › Developer.") }
        switch DevQuery.parse(query) {
        case let .linearIssue(key)?:
            guard let issue = try await linear.issue(key) else { throw DevAPI.Failure(message: "No issue \(key) in your Linear.") }
            return LinearAnswer(headline: issue.title, detail: issue.identifier, issue: issue)
        case let .linearSearch(text)?:
            let found = try await linear.search(text)
            return LinearAnswer(headline: "Issues matching “\(text)”", detail: "\(found.count) found", issues: found)
        default:
            linear.refreshSoon()
            let mine = linear.mine
            let started = mine.filter(\.started).count
            return LinearAnswer(headline: "Your issues", detail: [started > 0 ? "\(started) in progress" : nil, "\(mine.count) open"]
                .compactMap { $0 }.joined(separator: " · "), issues: mine)
        }
    }
}
