import AppKit
import Combine
import NotchKit
import SwiftUI

/// Vercel in the notch: your deployments as they build, a ring per push (one segment per project,
/// filling Queued → Building → Ready), a Prompt when a preview is ready or a build fails, and the
/// recent deployments for Home and Search.
///
/// Signs in with an access token (kept in the Keychain). Read-only apart from the actions you pick:
/// redeploy, cancel, promote to production.
@MainActor
final class VercelService: ObservableObject {
    static let shared = VercelService()

    enum Connection: Equatable {
        case off, connecting
        case connected(user: String)
        case failed(String)
        var user: String? { if case let .connected(u) = self { u } else { nil } }
    }

    struct Deployment: Identifiable, Equatable {
        enum State: String { case queued, building, ready, error, canceled }
        let id: String
        let project: String
        let projectID: String?
        let teamID: String?
        let url: URL?
        let inspector: URL?
        let state: State
        let production: Bool
        let branch: String?
        let sha: String?
        let message: String?
        let creatorID: String?
        let creator: String?
        let created: Date
        let ready: Date?

        var isDone: Bool { state == .ready || state == .error || state == .canceled }
        var label: String { production ? "Production" : "Preview" }

        /// Queued, Building, Ready, as the ring's three steps for this project.
        var steps: [CIRing.Step] {
            let states: [CIStepState] = switch state {
            case .queued: [.running, .queued, .queued]
            case .building: [.success, .running, .queued]
            case .ready: [.success, .success, .success]
            case .error: [.success, .failure, .skipped]
            case .canceled: [.success, .cancelled, .cancelled]
            }
            return zip(["Queued", "Building", "Ready"], states).map { CIRing.Step(job: project, name: $0, state: $1) }
        }
    }

    /// The deployments from one push (or one deployment alone), followed until they're done.
    struct Followed: Identifiable, Equatable {
        let id: String // the commit, or the deployment
        var deployments: [Deployment]
        let started: Date
        var finished: Date?
        var ring: CIRing { CIRing(steps: deployments.flatMap(\.steps)) }
        var title: String {
            let names = deployments.map(\.project)
            return names.count > 2 ? "\(names[0]) +\(names.count - 1)" : names.joined(separator: ", ")
        }
        var branch: String? { deployments.first?.branch }
        var url: URL? { deployments.count == 1 ? (deployments[0].isDone && deployments[0].state == .ready ? deployments[0].url : deployments[0].inspector) : deployments.first?.inspector }
    }

    @Published private(set) var connection: Connection = .off
    @Published private(set) var recent: [Deployment] = []
    @Published private(set) var followed: [Followed] = []

    /// The push to draw: one still building first, else the latest to finish.
    var current: Followed? { followed.first { $0.finished == nil } ?? followed.last }

    private var token: String?
    private var userID: String?
    private var teams: [String?] = [nil]
    private var cancellables = Set<AnyCancellable>()
    private var pollTask: Task<Void, Never>?
    private var seen = Set<String>()
    private var seeded = false
    /// Polled fast until then: after a push, or while something builds.
    private var fastUntil = Date.distantPast

    func start() {
        AppSettings.shared.$vercelEnabled.removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async { on ? self?.connect() : self?.disconnect() }
        }.store(in: &cancellables)
    }

    func connect() {
        guard AppSettings.shared.vercelEnabled else { return }
        pollTask?.cancel()
        guard let saved = DevKeys.get("vercel") else {
            connection = .failed("Paste an access token below.")
            return
        }
        token = saved
        connection = .connecting
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (json, code) = try await call("/v2/user")
                guard code == 200, let user = (json as? [String: Any])?["user"] as? [String: Any] else {
                    throw DevAPI.Failure(message: code == 401 || code == 403 ? "Vercel didn't accept the token." : "Vercel answered \(code).")
                }
                userID = user["id"] as? String
                let (t, _) = try await call("/v2/teams?limit=20")
                let ids = ((t as? [String: Any])?["teams"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                teams = [nil] + ids
                connection = .connected(user: user["username"] as? String ?? user["email"] as? String ?? "you")
            } catch {
                connection = .failed(error.localizedDescription)
                return
            }
            while !Task.isCancelled, connection.user != nil {
                await poll()
                let fast = Date() < fastUntil || followed.contains { $0.finished == nil }
                try? await Task.sleep(for: .seconds(fast ? 5 : 60))
            }
        }
    }

    func disconnect() {
        pollTask?.cancel()
        token = nil
        connection = .off
        recent = []
        followed = []
        seen = []
        seeded = false
    }

    /// A push just happened somewhere: look often for the deployments it starts.
    func kick() {
        guard connection.user != nil else { return }
        fastUntil = Date().addingTimeInterval(150)
        pollTask?.cancel()
        connect()
    }

    // MARK: - Polling

    private func poll() async {
        var all: [Deployment] = []
        for team in teams {
            let q = team.map { "&teamId=\($0)" } ?? ""
            guard let (json, code) = try? await call("/v6/deployments?limit=20\(q)"), code == 200,
                  let list = (json as? [String: Any])?["deployments"] as? [[String: Any]] else { continue }
            all += list.compactMap { Self.deployment($0, team: team) }
        }
        var unique: [String: Deployment] = [:]
        for d in all { unique[d.id] = d }
        let sorted = unique.values.sorted { $0.created > $1.created }
        recent = Array(sorted.prefix(30))

        // New ones of yours start being followed; followed ones are brought up to date.
        for d in sorted where !seen.contains(d.id) {
            seen.insert(d.id)
            guard seeded, d.creatorID == nil || d.creatorID == userID, !d.isDone || Date().timeIntervalSince(d.created) < 120 else { continue }
            follow(d)
        }
        seeded = true
        for i in followed.indices where followed[i].finished == nil {
            followed[i].deployments = followed[i].deployments.map { unique[$0.id] ?? $0 }
            if followed[i].deployments.allSatisfy(\.isDone) { finish(followed[i].id) }
        }
    }

    private func follow(_ d: Deployment) {
        let key = d.sha ?? d.id
        if let i = followed.firstIndex(where: { $0.id == key }) {
            if !followed[i].deployments.contains(where: { $0.id == d.id }) { followed[i].deployments.append(d) }
            followed[i].finished = nil
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                followed.append(Followed(id: key, deployments: [d], started: d.created))
            }
        }
        if d.isDone { if let f = followed.first(where: { $0.id == key }), f.deployments.allSatisfy(\.isDone) { finish(key) } }
    }

    private func finish(_ id: String) {
        guard let i = followed.firstIndex(where: { $0.id == id }), followed[i].finished == nil else { return }
        followed[i].finished = Date()
        let f = followed[i]
        let level = AppSettings.shared.githubAlerts
        if let failed = f.deployments.first(where: { $0.state == .error }) {
            if level != .off {
                NotchPresenter.shared.offer(Prompt(icon: "xmark.octagon.fill", tint: .systemRed, title: "Deploy failed: \(failed.project)",
                                                   detail: [failed.branch, failed.message].compactMap { $0 }.joined(separator: " · "),
                                                   actions: [.init(title: "Open Logs", primary: true) { if let u = failed.inspector { NSWorkspace.shared.open(u) } },
                                                             .init(title: "Redeploy") { [weak self] in self?.redeploy(failed) }]), peekFor: 8)
            }
        } else if let ready = f.deployments.first(where: { $0.state == .ready }), level != .off {
            let others = f.deployments.count - 1
            if ready.production {
                ActivityCenter.shared.show(.notice(title: "Live on production", detail: "\(f.title)\(ready.url.map { " · \($0.host() ?? "")" } ?? "")",
                                                   icon: "checkmark.circle.fill", tone: .success), for: 5) { if let u = ready.url { NSWorkspace.shared.open(u) } }
            } else {
                NotchPresenter.shared.offer(Prompt(icon: "eye.circle.fill", tint: .systemGreen, title: "Preview ready: \(ready.project)\(others > 0 ? " +\(others)" : "")",
                                                   detail: [ready.branch, ready.url?.host()].compactMap { $0 }.joined(separator: " · "),
                                                   actions: [.init(title: "Open", primary: true) { if let u = ready.url { NSWorkspace.shared.open(u) } },
                                                             .init(title: "Copy URL") { Self.copy(ready.url?.absoluteString ?? "", what: "preview link") }],
                                                   dismissTitle: "Later"), peekFor: 7)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, followed.first(where: { $0.id == id })?.finished != nil else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self.followed.removeAll { $0.id == id } }
        }
    }

    private static func deployment(_ d: [String: Any], team: String?) -> Deployment? {
        guard let id = d["uid"] as? String ?? d["id"] as? String else { return nil }
        let raw = (d["state"] as? String ?? d["readyState"] as? String ?? "").uppercased()
        let state: Deployment.State = switch raw {
        case "READY": .ready
        case "ERROR": .error
        case "CANCELED": .canceled
        case "BUILDING": .building
        default: .queued
        }
        let meta = d["meta"] as? [String: Any] ?? [:]
        let creator = d["creator"] as? [String: Any]
        return Deployment(id: id, project: d["name"] as? String ?? "Project", projectID: d["projectId"] as? String, teamID: team,
                          url: (d["url"] as? String).flatMap { URL(string: "https://\($0)") },
                          inspector: (d["inspectorUrl"] as? String).flatMap(URL.init(string:)),
                          state: state, production: d["target"] as? String == "production",
                          branch: meta["githubCommitRef"] as? String ?? meta["gitlabCommitRef"] as? String ?? meta["bitbucketCommitRef"] as? String,
                          sha: meta["githubCommitSha"] as? String ?? meta["gitlabCommitSha"] as? String,
                          message: (meta["githubCommitMessage"] as? String ?? meta["gitlabCommitMessage"] as? String)?
                            .split(separator: "\n").first.map(String.init),
                          creatorID: creator?["uid"] as? String, creator: creator?["username"] as? String,
                          created: DevAPI.date(d["created"] ?? d["createdAt"]) ?? Date(), ready: DevAPI.date(d["ready"]))
    }

    // MARK: - Actions

    /// Builds the same commit again (as the same target).
    func redeploy(_ d: Deployment) {
        Task {
            var body: [String: Any] = ["name": d.project, "deploymentId": d.id]
            if d.production { body["target"] = "production" }
            let q = d.teamID.map { "&teamId=\($0)" } ?? ""
            let ok = (try? await call("/v13/deployments?forceNew=1\(q)", method: "POST", body: body)).map { (200..<300).contains($0.1) } ?? false
            Self.notice(ok ? "Redeploying \(d.project)" : "Couldn't redeploy", detail: ok ? (d.branch ?? d.label) : "Vercel said no: try from its dashboard",
                        icon: ok ? "arrow.clockwise.circle.fill" : "exclamationmark.triangle.fill", tone: ok ? .info : .warning)
            if ok { kick() }
        }
    }

    func cancel(_ d: Deployment) {
        Task {
            let q = d.teamID.map { "?teamId=\($0)" } ?? ""
            let ok = (try? await call("/v12/deployments/\(d.id)/cancel\(q)", method: "PATCH")).map { (200..<300).contains($0.1) } ?? false
            Self.notice(ok ? "Cancelled \(d.project)" : "Couldn't cancel", detail: d.branch ?? d.label, icon: "stop.circle.fill", tone: ok ? .info : .warning)
            if ok { kick() }
        }
    }

    /// Makes this deployment production (also how you roll back to an older one).
    func promote(_ d: Deployment) {
        guard let project = d.projectID else { return }
        Task {
            let q = d.teamID.map { "?teamId=\($0)" } ?? ""
            let ok = (try? await call("/v10/projects/\(project)/promote/\(d.id)\(q)", method: "POST")).map { (200..<300).contains($0.1) } ?? false
            Self.notice(ok ? "Promoting \(d.project)" : "Couldn't promote", detail: ok ? "This deployment becomes production" : "Vercel said no: try from its dashboard",
                        icon: ok ? "arrow.up.circle.fill" : "exclamationmark.triangle.fill", tone: ok ? .success : .warning)
            if ok { kick() }
        }
    }

    static func copy(_ text: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice("Copied \(what)", detail: text, icon: "doc.on.doc", tone: .info)
    }

    static func notice(_ title: String, detail: String, icon: String, tone: NoticeTone) {
        ActivityCenter.shared.show(.notice(title: title, detail: detail, icon: icon, tone: tone), for: 3)
    }

    /// The Glance's click: the push being followed, else the latest deployment.
    func openTop() {
        if let u = current?.url ?? recent.first?.inspector { NSWorkspace.shared.open(u) }
        else { NSWorkspace.shared.open(URL(string: "https://vercel.com/dashboard")!) }
    }

    func call(_ path: String, method: String = "GET", body: Any? = nil) async throws -> (Any?, Int) {
        guard let token else { throw DevAPI.Failure(message: "Not signed in to Vercel.") }
        let r = try await DevAPI.json(URL(string: "https://api.vercel.com" + path)!, method: method,
                                      headers: ["Authorization": "Bearer \(token)"], body: body)
        if r.1 == 401 || r.1 == 403, connection.user != nil, method == "GET" { connection = .failed("Vercel didn't accept the token.") }
        return r
    }

    // MARK: - Debug

    /// A pretend push building two projects, one failing if asked.
    func simulate(fail: Bool) {
        let sha = UUID().uuidString
        func make(_ name: String, _ state: Deployment.State) -> Deployment {
            Deployment(id: "\(name)-\(sha)", project: name, projectID: nil, teamID: nil, url: URL(string: "https://\(name)-demo.vercel.app"),
                       inspector: URL(string: "https://vercel.com"), state: state, production: false, branch: "feat/glass", sha: sha,
                       message: "Glass edge sync", creatorID: userID, creator: nil, created: Date(), ready: nil)
        }
        if connection.user == nil { connection = .connected(user: "demo") }
        followed.append(Followed(id: sha, deployments: [make("web", .queued), make("docs", .queued)], started: Date()))
        if recent.isEmpty {
            recent = [Deployment(id: "old1", project: "web", projectID: "p1", teamID: nil, url: URL(string: "https://web-demo.vercel.app"),
                                 inspector: URL(string: "https://vercel.com"), state: .ready, production: true, branch: "main", sha: nil,
                                 message: "Ship the new pricing page", creatorID: nil, creator: "demo", created: Date().addingTimeInterval(-3600 * 5), ready: nil),
                      Deployment(id: "old2", project: "docs", projectID: "p2", teamID: nil, url: URL(string: "https://docs-demo.vercel.app"),
                                 inspector: URL(string: "https://vercel.com"), state: .error, production: false, branch: "fix/search", sha: nil,
                                 message: "Search index for the guides", creatorID: nil, creator: "demo", created: Date().addingTimeInterval(-3600 * 26), ready: nil)]
        }
        let plan: [(Double, Deployment.State, Deployment.State)] = [(3, .building, .queued), (6, .building, .building), (12, .ready, .building),
                                                                    (16, .ready, fail ? .error : .ready)]
        for (t, a, b) in plan {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, let i = followed.firstIndex(where: { $0.id == sha }) else { return }
                followed[i].deployments = [make("web", a), make("docs", b)]
                if a == .ready, b == .ready || b == .error { finish(sha) }
            }
        }
    }
}
