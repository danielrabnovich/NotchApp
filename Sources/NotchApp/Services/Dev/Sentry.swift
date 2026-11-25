import AppKit
import Combine

/// Sentry in the notch: your organization's unresolved issues from the last day on Home, busiest
/// first, and a Prompt when a new one appears or one spikes. Read-only apart from Resolve, which only
/// happens when you pick it.
///
/// Signs in with a user auth token (org:read, project:read, event:read; event:write for Resolve),
/// kept in the Keychain, and the organization's slug.
@MainActor
final class SentryService: ObservableObject {
    static let shared = SentryService()

    enum Connection: Equatable {
        case off, connecting
        case connected(org: String)
        case failed(String)
        var org: String? { if case let .connected(o) = self { o } else { nil } }
    }

    struct Issue: Identifiable, Equatable {
        let id: String
        let shortID: String
        let title: String
        let culprit: String?
        let project: String
        let level: String
        let url: URL?
        /// Events in the last 24 hours, and the users they hit.
        let events: Int
        let users: Int
        let firstSeen: Date
        let lastSeen: Date
        /// Events per hour over the last day, oldest first.
        let hourly: [Int]

        var isError: Bool { level == "error" || level == "fatal" }
    }

    @Published private(set) var connection: Connection = .off
    @Published private(set) var issues: [Issue] = []

    private var token: String?
    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// Issues already seen, so only new ones are announced; empty until the first poll seeds it.
    private var seen = Set<String>()
    private var seeded = false
    /// Spikes announced today, by issue, so one storm is one Prompt.
    private var spiked: [String: Date] = [:]

    private static let base = URL(string: "https://sentry.io/api/0/")!

    func start() {
        let s = AppSettings.shared
        Publishers.CombineLatest(s.$sentryEnabled.removeDuplicates(), s.$sentryOrg.removeDuplicates())
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] on, _ in on ? self?.connect() : self?.disconnect() }
            .store(in: &cancellables)
    }

    func connect() {
        guard AppSettings.shared.sentryEnabled else { return }
        pollTask?.cancel()
        let org = AppSettings.shared.sentryOrg.trimmingCharacters(in: .whitespaces).lowercased()
        guard !org.isEmpty else { connection = .failed("Enter your organization's slug (from its URL)."); return }
        guard let saved = DevKeys.get("sentry") else { connection = .failed("Paste an auth token below."); return }
        token = saved
        connection = .connecting
        seen = []
        seeded = false
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (json, code) = try await get("organizations/\(org)/")
                guard code == 200, let o = json as? [String: Any] else {
                    throw DevAPI.Failure(message: code == 401 ? "Sentry didn't accept the token." :
                                         code == 403 ? "The token can't read \(org) (it needs org:read)." :
                                         code == 404 ? "No organization “\(org)” for this token." : "Sentry answered \(code).")
                }
                connection = .connected(org: o["name"] as? String ?? org)
            } catch {
                connection = .failed(error.localizedDescription)
                return
            }
            while !Task.isCancelled, connection.org != nil {
                await poll(org: org)
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        token = nil
        issues = []
        connection = .off
    }

    /// Marks it resolved in Sentry.
    func resolve(_ issue: Issue) {
        let org = AppSettings.shared.sentryOrg.lowercased()
        Task {
            let (_, code) = (try? await request("organizations/\(org)/issues/?id=\(issue.id)", method: "PUT", body: ["status": "resolved"])) ?? (nil, 0)
            if code == 200 {
                issues.removeAll { $0.id == issue.id }
                ActivityCenter.shared.show(.notice(title: "Resolved \(issue.shortID)", detail: issue.title, icon: "checkmark.circle.fill", tone: .success), for: 2.5)
            } else {
                ActivityCenter.shared.show(.notice(title: "Couldn't resolve \(issue.shortID)",
                                                   detail: code == 403 ? "The token needs event:write" : "Sentry answered \(code)",
                                                   icon: "exclamationmark.triangle.fill", tone: .warning), for: 3)
            }
        }
    }

    // MARK: - Polling

    private func poll(org: String) async {
        guard let (json, code) = try? await get("organizations/\(org)/issues/?query=is:unresolved&statsPeriod=24h&sort=freq&limit=25"),
              code == 200, let list = json as? [[String: Any]] else { return }
        let fresh = list.compactMap(Self.issue)
        defer {
            issues = fresh
            seen.formUnion(fresh.map(\.id))
            seeded = true
        }
        guard seeded, AppSettings.shared.githubAlerts != .off else { return }
        for issue in fresh where !seen.contains(issue.id) && issue.firstSeen > Date().addingTimeInterval(-3600) {
            announce(issue, title: "New in \(issue.project)", icon: "ladybug.fill")
        }
        let today = Calendar.current.startOfDay(for: Date())
        for issue in fresh where Self.isSpiking(issue.hourly) && (spiked[issue.id] ?? .distantPast) < today {
            spiked[issue.id] = Date()
            announce(issue, title: "Spiking in \(issue.project): \(issue.hourly.last ?? 0) in the last hour", icon: "chart.line.uptrend.xyaxis")
        }
    }

    private func announce(_ issue: Issue, title: String, icon: String) {
        NotchPresenter.shared.offer(Prompt(icon: icon, tint: issue.isError ? .systemRed : .systemOrange, title: title,
                                           detail: issue.title,
                                           actions: [.init(title: "Open", primary: true) { if let u = issue.url { NSWorkspace.shared.open(u) } },
                                                     .init(title: "Resolve") { SentryService.shared.resolve(issue) }]), peekFor: 8)
    }

    /// A spike: the last hour has at least 20 events and five times its usual hourly rate.
    nonisolated static func isSpiking(_ hourly: [Int]) -> Bool {
        guard hourly.count >= 4, let last = hourly.last, last >= 20 else { return false }
        let before = hourly.dropLast()
        let usual = Double(before.reduce(0, +)) / Double(before.count)
        return Double(last) >= max(1, usual) * 5
    }

    nonisolated static func issue(_ o: [String: Any]) -> Issue? {
        guard let id = o["id"] as? String, let title = o["title"] as? String else { return nil }
        let project = o["project"] as? [String: Any]
        let hourly = ((o["stats"] as? [String: Any])?["24h"] as? [[Any]] ?? []).compactMap { pair in
            pair.count == 2 ? (pair[1] as? Int ?? (pair[1] as? Double).map(Int.init)) : nil
        }
        return Issue(id: id, shortID: o["shortId"] as? String ?? id, title: title,
                     culprit: (o["culprit"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                     project: project?["slug"] as? String ?? project?["name"] as? String ?? "",
                     level: o["level"] as? String ?? "error",
                     url: (o["permalink"] as? String).flatMap(URL.init(string:)),
                     events: Int(o["count"] as? String ?? "") ?? o["count"] as? Int ?? hourly.reduce(0, +),
                     users: o["userCount"] as? Int ?? 0,
                     firstSeen: date(o["firstSeen"]) ?? .distantPast,
                     lastSeen: date(o["lastSeen"]) ?? .distantPast,
                     hourly: hourly)
    }

    /// Sentry's times carry fractional seconds ("2026-11-25T21:04:05.123456Z"), which the plain
    /// ISO 8601 reading turns down.
    nonisolated static func date(_ any: Any?) -> Date? {
        guard let text = any as? String else { return DevAPI.date(any) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        // More than three digits of fraction: keep the milliseconds.
        if let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = text[text.index(after: dot)..<end]
            if let d = f.date(from: String(text[..<dot]) + "." + digits.prefix(3) + text[end...]) { return d }
        }
        return DevAPI.date(text)
    }

    // MARK: - API

    private func get(_ path: String) async throws -> (Any?, Int) { try await request(path) }

    private func request(_ path: String, method: String = "GET", body: Any? = nil) async throws -> (Any?, Int) {
        guard let token, let url = URL(string: path, relativeTo: Self.base) else { throw DevAPI.Failure(message: "Not signed in to Sentry.") }
        return try await DevAPI.json(url, method: method, headers: ["Authorization": "Bearer \(token)"], body: body)
    }
}
