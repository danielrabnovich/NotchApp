import AppKit
import Combine
import SwiftUI

/// Linear in the notch: the issue you're on (in progress) beside it, your issues on Home, issues in
/// Search by key ("ENG-123") or words, and a heads-up when one is assigned to you or you're
/// mentioned. Actions you pick: start, mark done, assign to yourself.
///
/// Signs in with a personal API key (kept in the Keychain).
@MainActor
final class LinearService: ObservableObject {
    static let shared = LinearService()

    enum Connection: Equatable {
        case off, connecting
        case connected(user: String)
        case failed(String)
        var user: String? { if case let .connected(u) = self { u } else { nil } }
    }

    struct Issue: Identifiable, Equatable {
        struct WorkflowState: Equatable {
            let id: String
            let name: String
            /// triage, backlog, unstarted, started, completed, canceled
            let type: String
            let color: String
        }
        let id: String
        let identifier: String
        let title: String
        let url: URL
        let priority: Int
        let priorityLabel: String
        let branch: String?
        let state: WorkflowState
        let teamID: String?
        let assignee: String?
        let assigneeID: String?
        let labels: [String]
        let project: String?
        let cycle: String?
        let estimate: Double?
        let due: String?
        let description: String?
        let links: [(title: String, url: URL)]
        let updated: Date

        static func == (a: Issue, b: Issue) -> Bool {
            a.id == b.id && a.state == b.state && a.title == b.title && a.assigneeID == b.assigneeID && a.updated == b.updated
        }

        var started: Bool { state.type == "started" }
        var done: Bool { state.type == "completed" || state.type == "canceled" }
    }

    struct Notice: Identifiable, Equatable {
        let id: String
        let type: String
        let actor: String?
        let issue: String?
        let title: String?
        let url: URL?
        let created: Date
        var unread: Bool
    }

    @Published private(set) var connection: Connection = .off
    /// Yours and not done: in progress first.
    @Published private(set) var mine: [Issue] = []
    @Published private(set) var notices: [Notice] = []

    var userID: String?
    var inProgress: [Issue] { mine.filter(\.started) }
    var unreadCount: Int { notices.filter(\.unread).count }

    private var key: String?
    private var cancellables = Set<AnyCancellable>()
    private var pollTask: Task<Void, Never>?
    private var seen = Set<String>()
    private var seeded = false
    /// Each team's workflow, for Start and Done.
    private var teamStates: [String: [Issue.WorkflowState]] = [:]

    func start() {
        AppSettings.shared.$linearEnabled.removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async { on ? self?.connect() : self?.disconnect() }
        }.store(in: &cancellables)
    }

    func connect() {
        guard AppSettings.shared.linearEnabled else { return }
        pollTask?.cancel()
        guard let saved = DevKeys.get("linear") else {
            connection = .failed("Paste a personal API key below.")
            return
        }
        key = saved
        connection = .connecting
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await query("query { viewer { id name displayName } }")
                guard let viewer = data["viewer"] as? [String: Any] else { throw DevAPI.Failure(message: "Linear didn't say who you are.") }
                userID = viewer["id"] as? String
                connection = .connected(user: viewer["displayName"] as? String ?? viewer["name"] as? String ?? "you")
            } catch {
                connection = .failed(error.localizedDescription)
                return
            }
            while !Task.isCancelled, connection.user != nil {
                await poll()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func disconnect() {
        pollTask?.cancel()
        key = nil
        connection = .off
        mine = []
        notices = []
        seen = []
        seeded = false
    }

    func refreshSoon() {
        Task { await poll() }
    }

    // MARK: - Polling

    static let issueFields = """
    id identifier title url priority priorityLabel branchName estimate dueDate description updatedAt
    state { id name type color } team { id } assignee { id name } project { name } cycle { number name }
    labels(first: 6) { nodes { name } } attachments(first: 6) { nodes { title url } }
    """

    private func poll() async {
        let q = """
        query { viewer { assignedIssues(first: 40, orderBy: updatedAt, filter: { state: { type: { nin: ["completed", "canceled"] } } }) {
          nodes { \(Self.issueFields) } } }
          notifications(first: 30) { nodes { id type readAt createdAt actor { name }
            ... on IssueNotification { issue { identifier title url } } } } }
        """
        guard let data = try? await query(q) else { return }
        let nodes = ((data["viewer"] as? [String: Any])?["assignedIssues"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let rank = ["started": 0, "unstarted": 1, "triage": 2, "backlog": 3]
        mine = nodes.compactMap(Self.issue).sorted {
            (rank[$0.state.type] ?? 9, $0.priority == 0 ? 9 : $0.priority) < (rank[$1.state.type] ?? 9, $1.priority == 0 ? 9 : $1.priority)
        }
        let list = ((data["notifications"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { n -> Notice? in
            guard let id = n["id"] as? String else { return nil }
            let issue = n["issue"] as? [String: Any]
            return Notice(id: id, type: n["type"] as? String ?? "", actor: (n["actor"] as? [String: Any])?["name"] as? String,
                          issue: issue?["identifier"] as? String, title: issue?["title"] as? String,
                          url: (issue?["url"] as? String).flatMap(URL.init(string:)), created: DevAPI.date(n["createdAt"]) ?? Date(),
                          unread: n["readAt"] == nil || n["readAt"] is NSNull)
        }
        notices = list
        let fresh = list.filter { $0.unread && !seen.contains($0.id) }
        list.forEach { seen.insert($0.id) }
        if seeded { fresh.reversed().forEach(announce) }
        seeded = true
    }

    static func issue(_ n: [String: Any]) -> Issue? {
        guard let id = n["id"] as? String, let identifier = n["identifier"] as? String,
              let url = (n["url"] as? String).flatMap(URL.init(string:)), let s = n["state"] as? [String: Any] else { return nil }
        let cycle = n["cycle"] as? [String: Any]
        return Issue(id: id, identifier: identifier, title: n["title"] as? String ?? "", url: url, priority: n["priority"] as? Int ?? 0,
                     priorityLabel: n["priorityLabel"] as? String ?? "", branch: n["branchName"] as? String,
                     state: .init(id: s["id"] as? String ?? "", name: s["name"] as? String ?? "", type: s["type"] as? String ?? "",
                                  color: s["color"] as? String ?? "#888888"),
                     teamID: (n["team"] as? [String: Any])?["id"] as? String,
                     assignee: (n["assignee"] as? [String: Any])?["name"] as? String, assigneeID: (n["assignee"] as? [String: Any])?["id"] as? String,
                     labels: ((n["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                     project: (n["project"] as? [String: Any])?["name"] as? String,
                     cycle: cycle.map { ($0["name"] as? String)?.nilIfEmpty ?? "Cycle \($0["number"] as? Int ?? 0)" },
                     estimate: n["estimate"] as? Double, due: n["dueDate"] as? String,
                     description: (n["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                     links: ((n["attachments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { a in
                         (a["url"] as? String).flatMap(URL.init(string:)).map { (a["title"] as? String ?? $0.absoluteString, $0) }
                     },
                     updated: DevAPI.date(n["updatedAt"]) ?? Date())
    }

    private func announce(_ n: Notice) {
        let level = AppSettings.shared.githubAlerts
        guard level != .off else { return }
        let open: @MainActor () -> Void = { [weak self] in self?.open(n) }
        let subject = [n.issue, n.title].compactMap { $0 }.joined(separator: " ")
        switch n.type {
        case "issueAssignedToYou":
            let issueKey = n.issue
            NotchPresenter.shared.offer(Prompt(icon: "person.crop.circle.badge.plus", tint: .systemIndigo, title: "Assigned to you",
                                               detail: subject + (n.actor.map { " · by \($0)" } ?? ""),
                                               actions: [.init(title: "Open", primary: true, run: open),
                                                         .init(title: "Start") { [weak self] in
                                                             guard let self, let issueKey else { return }
                                                             Task { if let issue = try? await self.issue(issueKey) { self.move(issue, to: "started") } }
                                                         }], dismissTitle: "Later"), peekFor: 7)
        case "issueMention", "issueCommentMention", "issueNewComment":
            if n.type == "issueNewComment", level != .everything { return }
            ActivityCenter.shared.show(.notice(title: n.type == "issueNewComment" ? "New comment" : "Mentioned by \(n.actor ?? "someone")",
                                               detail: subject, icon: n.type == "issueNewComment" ? "bubble.left.fill" : "at", tone: .info), for: 5, onClick: open)
        default:
            guard level == .everything else { return }
            ActivityCenter.shared.show(.notice(title: Self.describe(n.type), detail: subject, icon: "circle.dashed", tone: .info), for: 5, onClick: open)
        }
    }

    /// "issueStatusChanged" → "Status changed".
    static func describe(_ type: String) -> String {
        let words = type.replacingOccurrences(of: "issue", with: "").reduce("") { $0 + ($1.isUppercase ? " " + $1.lowercased() : String($1)) }
        let line = words.trimmingCharacters(in: .whitespaces)
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    // MARK: - Lookups for Search

    func issue(_ key: String) async throws -> Issue? {
        let escaped = key.replacingOccurrences(of: "\"", with: "")
        let data = try await query("query { issue(id: \"\(escaped)\") { \(Self.issueFields) } }")
        return (data["issue"] as? [String: Any]).flatMap(Self.issue)
    }

    func search(_ text: String) async throws -> [Issue] {
        let data = try await query("query($t: String!) { searchIssues(term: $t, first: 15) { nodes { \(Self.issueFields) } } }", variables: ["t": text])
        return ((data["searchIssues"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap(Self.issue)
    }

    // MARK: - Actions

    /// Moves an issue to its team's first state of this type: "started" (Start), "completed" (Done),
    /// "unstarted" (back to Todo).
    func move(_ issue: Issue, to type: String) {
        Task {
            do {
                guard let team = issue.teamID, let state = try await states(team).first(where: { $0.type == type }) else {
                    throw DevAPI.Failure(message: "No such state in its team")
                }
                let data = try await query("mutation($id: String!, $s: String!) { issueUpdate(id: $id, input: { stateId: $s }) { success } }",
                                           variables: ["id": issue.id, "s": state.id])
                guard (data["issueUpdate"] as? [String: Any])?["success"] as? Bool == true else { throw DevAPI.Failure(message: "Linear said no") }
                VercelService.notice("\(issue.identifier) → \(state.name)", detail: issue.title,
                                     icon: type == "completed" ? "checkmark.circle.fill" : "circle.lefthalf.filled", tone: .success)
                await poll()
            } catch {
                VercelService.notice("Couldn't change \(issue.identifier)", detail: error.localizedDescription, icon: "exclamationmark.triangle.fill", tone: .warning)
            }
        }
    }

    func assignToMe(_ issue: Issue) {
        guard let me = userID else { return }
        Task {
            let data = try? await query("mutation($id: String!, $a: String!) { issueUpdate(id: $id, input: { assigneeId: $a }) { success } }",
                                        variables: ["id": issue.id, "a": me])
            let ok = (data?["issueUpdate"] as? [String: Any])?["success"] as? Bool == true
            VercelService.notice(ok ? "\(issue.identifier) is yours" : "Couldn't assign \(issue.identifier)", detail: issue.title,
                                 icon: ok ? "person.crop.circle.badge.checkmark" : "exclamationmark.triangle.fill", tone: ok ? .success : .warning)
            if ok { await poll() }
        }
    }

    private func states(_ team: String) async throws -> [Issue.WorkflowState] {
        if let cached = teamStates[team] { return cached }
        let data = try await query("query($t: String!) { team(id: $t) { states { nodes { id name type color position } } } }", variables: ["t": team])
        let nodes = ((data["team"] as? [String: Any])?["states"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let list = nodes.sorted { ($0["position"] as? Double ?? 0) < ($1["position"] as? Double ?? 0) }.map {
            Issue.WorkflowState(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", type: $0["type"] as? String ?? "",
                                color: $0["color"] as? String ?? "#888888")
        }
        teamStates[team] = list
        return list
    }

    func open(_ issue: Issue) { NSWorkspace.shared.open(issue.url) }

    /// Debug: pretend issues, to look at the Glance, Home and Search without an account.
    func simulate() {
        func make(_ n: Int, _ title: String, _ type: String, _ name: String, _ color: String, _ p: Int) -> Issue {
            Issue(id: "demo\(n)", identifier: "ENG-\(n)", title: title, url: URL(string: "https://linear.app")!, priority: p,
                  priorityLabel: ["No priority", "Urgent", "High", "Medium", "Low"][p], branch: "phil/eng-\(n)",
                  state: .init(id: type, name: name, type: type, color: color), teamID: nil, assignee: "Phil", assigneeID: "me",
                  labels: n == 142 ? ["Bug", "Notch"] : [], project: "Glass", cycle: "Cycle 12", estimate: 3, due: nil,
                  description: "The edge of the glass drifts from the notch while it springs open.\nRepro: open and close quickly.",
                  links: [("GitHub PR #3", URL(string: "https://github.com/danielrabnovich/NotchApp/pull/3")!)], updated: Date().addingTimeInterval(Double(-n * 600)))
        }
        userID = "me"
        connection = .connected(user: "demo")
        mine = [make(142, "Glass edge drifts during spring", "started", "In Progress", "#f2c94c", 2),
                make(150, "CI ring per job, not per step", "unstarted", "Todo", "#e2e2e2", 3),
                make(151, "Vercel previews in the notch", "unstarted", "Todo", "#e2e2e2", 1),
                make(97, "Clean up old Glance names", "backlog", "Backlog", "#bec2c8", 4)]
    }

    func open(_ n: Notice) {
        if let url = n.url { NSWorkspace.shared.open(url) }
        guard n.unread else { return }
        if let i = notices.firstIndex(where: { $0.id == n.id }) { notices[i].unread = false }
        let now = ISO8601DateFormatter().string(from: Date())
        Task { _ = try? await query("mutation($id: String!, $r: DateTime!) { notificationUpdate(id: $id, input: { readAt: $r }) { success } }",
                                    variables: ["id": n.id, "r": now]) }
    }

    /// The Glance's click: the issue you're on, else your top one, else your inbox.
    func openTop() {
        if let issue = inProgress.first ?? mine.first { open(issue) }
        else { NSWorkspace.shared.open(URL(string: "https://linear.app/inbox")!) }
    }

    func query(_ q: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        guard let key else { throw DevAPI.Failure(message: "Not signed in to Linear.") }
        let (json, code) = try await DevAPI.json(URL(string: "https://api.linear.app/graphql")!, method: "POST",
                                                 headers: ["Authorization": key], body: ["query": q, "variables": variables])
        if code == 401 || code == 403 {
            connection = .failed("Linear didn't accept the key.")
            throw DevAPI.Failure(message: "Linear didn't accept the key.")
        }
        let obj = json as? [String: Any]
        if let errors = obj?["errors"] as? [[String: Any]], let first = errors.first?["message"] as? String, obj?["data"] == nil || obj?["data"] is NSNull {
            throw DevAPI.Failure(message: first)
        }
        guard let data = obj?["data"] as? [String: Any] else { throw DevAPI.Failure(message: "Linear answered \(code).") }
        return data
    }
}

extension Color {
    /// "#5e6ad2" → a colour; grey when it isn't one.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
