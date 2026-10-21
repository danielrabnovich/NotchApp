import Foundation
import SwiftUI

// MARK: - Tokens

/// Token counts for one model in one hour (or summed over a period).
struct TokenCounts: Codable, Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    /// Prompt-cache writes kept for five minutes, and for an hour (priced differently).
    var cacheWrite = 0
    var cacheWriteLong = 0
    var requests = 0

    var total: Int { input + output + cacheRead + cacheWrite + cacheWriteLong }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                    cacheWrite: a.cacheWrite + b.cacheWrite, cacheWriteLong: a.cacheWriteLong + b.cacheWriteLong,
                    requests: a.requests + b.requests)
    }

    static func - (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(0, a.input - b.input), output: max(0, a.output - b.output), cacheRead: max(0, a.cacheRead - b.cacheRead),
                    cacheWrite: max(0, a.cacheWrite - b.cacheWrite), cacheWriteLong: max(0, a.cacheWriteLong - b.cacheWriteLong),
                    requests: max(0, a.requests - b.requests))
    }
}

// MARK: - Prices

/// What the same tokens would cost on each provider's pay-as-you-go API, in US dollars per
/// million tokens. Subscriptions (Claude Pro/Max, ChatGPT Plus/Pro, the GLM Coding Plan) don't bill
/// per token; this is the value of what you used, for comparing against what the plan costs.
/// Prices as published in October 2026: Anthropic's API pricing, OpenAI's API pricing, Z.ai's.
enum AgentPricing {
    struct Price {
        let input: Double
        let output: Double
        let cacheRead: Double
        /// Five-minute cache writes; providers without separate write pricing charge input.
        let cacheWrite: Double
        /// One-hour cache writes.
        let cacheWriteLong: Double

        init(_ input: Double, _ output: Double, read: Double, write: Double? = nil, writeLong: Double? = nil) {
            self.input = input
            self.output = output
            cacheRead = read
            cacheWrite = write ?? input
            cacheWriteLong = writeLong ?? write ?? input
        }

        /// Anthropic's ratios: cache reads 0.1×, five-minute writes 1.25×, one-hour writes 2× input.
        static func anthropic(_ input: Double, _ output: Double, read: Double? = nil) -> Price {
            Price(input, output, read: read ?? input * 0.1, write: input * 1.25, writeLong: input * 2)
        }
    }

    static let updated = "October 2026"

    /// Model id prefixes, most specific first (so "claude-opus-5-5" wins over "claude-opus-5").
    private static let table: [(String, Price)] = [
        // Anthropic
        ("claude-fable-5-1", .anthropic(10, 50, read: 0.25)),
        ("claude-mythos-5-1", .anthropic(10, 50, read: 0.25)),
        ("claude-fable-5", .anthropic(10, 50)),
        ("claude-mythos-5", .anthropic(10, 50)),
        ("claude-opus-5-5", .anthropic(4, 20, read: 0.2)),
        ("claude-opus-5", .anthropic(5, 25)),
        ("claude-opus-4-8", .anthropic(5, 25)),
        ("claude-opus-4-7", .anthropic(5, 25)),
        ("claude-opus-4-6", .anthropic(5, 25)),
        ("claude-opus-4-5", .anthropic(5, 25)),
        ("claude-opus-4-1", .anthropic(15, 75)),
        ("claude-opus-4", .anthropic(15, 75)),
        ("claude-sonnet-5-5", .anthropic(2, 10, read: 0.2)),
        ("claude-sonnet-5", .anthropic(2, 10, read: 0.2)),
        ("claude-sonnet-4", .anthropic(3, 15)),
        ("claude-3-7-sonnet", .anthropic(3, 15)),
        ("claude-3-5-sonnet", .anthropic(3, 15)),
        ("claude-haiku-5-5", .anthropic(0.10, 0.50)),
        ("claude-haiku-4-5", .anthropic(1, 5)),
        ("claude-3-5-haiku", .anthropic(0.8, 4)),
        ("claude-3-haiku", .anthropic(0.25, 1.25)),
        // OpenAI (Codex)
        ("gpt-6.1-sol", Price(2, 10, read: 0.1, write: 2.5)),
        ("gpt-6-astra", Price(10, 50, read: 1, write: 12.5)),
        ("gpt-6-sol", Price(2, 10, read: 0.2, write: 2.5)),
        ("gpt-6-luna", Price(0.1, 0.5, read: 0.01, write: 0.125)),
        ("gpt-5.6-terra", Price(2, 12, read: 0.2, write: 2.5)),
        ("gpt-5.6-luna", Price(0.2, 1.2, read: 0.02, write: 0.25)),
        ("gpt-5.6-cyber", Price(12.5, 75, read: 1.25, write: 15.625)),
        ("gpt-5.6", Price(4, 20, read: 0.4, write: 5)),
        ("gpt-5.5-pro", Price(30, 180, read: 30)),
        ("gpt-5.5", Price(5, 30, read: 0.5)),
        ("gpt-5.4-mini", Price(0.75, 4.5, read: 0.075)),
        ("gpt-5.4-nano", Price(0.2, 1.25, read: 0.02)),
        ("gpt-5.4-pro", Price(30, 180, read: 30)),
        ("gpt-5.4", Price(2.5, 15, read: 0.25)),
        ("gpt-5.3-codex", Price(1.75, 14, read: 0.175)),
        ("gpt-5.2", Price(1.75, 14, read: 0.175)),
        ("gpt-5.1-codex-mini", Price(0.25, 2, read: 0.025)),
        ("gpt-5.1", Price(1.25, 10, read: 0.125)),
        ("gpt-5-mini", Price(0.25, 2, read: 0.025)),
        ("gpt-5-nano", Price(0.05, 0.4, read: 0.005)),
        ("gpt-5", Price(1.25, 10, read: 0.125)),
        ("codex-mini", Price(1.5, 6, read: 0.375)),
        ("o4-mini", Price(1.1, 4.4, read: 0.275)),
        ("o3", Price(2, 8, read: 0.5)),
        // Z.ai (ZCode)
        ("glm-5.3-flash", Price(0.15, 0.5, read: 0.03)),
        ("glm-5.3", Price(1.4, 4.4, read: 0.26)),
        ("glm-5.2", Price(1.4, 4.4, read: 0.26)),
    ].sorted { $0.0.count > $1.0.count }

    /// "anthropic/claude-opus-5-5[1m]" → "claude-opus-5-5"; "GLM-5.3" → "glm-5.3".
    static func normalize(_ model: String) -> String {
        var m = model.lowercased()
        if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
        if let bracket = m.firstIndex(of: "[") { m = String(m[..<bracket]) }
        m = m.replacingOccurrences(of: "anthropic.", with: "").replacingOccurrences(of: "us.", with: "")
        return m.trimmingCharacters(in: .whitespaces)
    }

    static func price(for model: String) -> Price? {
        let m = normalize(model)
        return table.first { m.hasPrefix($0.0) }?.1
    }

    /// API value of some tokens, or nil for models without a public price (local models…).
    static func cost(_ c: TokenCounts, model: String) -> Double? {
        guard let p = price(for: model) else { return nil }
        let millions = { (n: Int) in Double(n) / 1_000_000 }
        return millions(c.input) * p.input + millions(c.output) * p.output + millions(c.cacheRead) * p.cacheRead
            + millions(c.cacheWrite) * p.cacheWrite + millions(c.cacheWriteLong) * p.cacheWriteLong
    }
}

// MARK: - Plans

/// The subscription behind an agent, found where the agent keeps it (or chosen in Settings).
struct AgentPlan: Equatable, Identifiable {
    var id: String
    var name: String
    /// US dollars a month, when one price applies.
    var monthly: Double?
    /// True when it pays per token rather than by subscription.
    var isAPI = false
    var detected = false

    static let api = AgentPlan(id: "api", name: "API", isAPI: true)

    /// Plans that can be picked for each tool.
    static func choices(for tool: AgentMonitor.Tool) -> [AgentPlan] {
        switch tool {
        case .claude:
            [AgentPlan(id: "pro", name: "Pro", monthly: 20), AgentPlan(id: "max5", name: "Max 5×", monthly: 100),
             AgentPlan(id: "max20", name: "Max 20×", monthly: 200), AgentPlan(id: "team", name: "Team"),
             AgentPlan(id: "enterprise", name: "Enterprise"), .api]
        case .codex:
            [AgentPlan(id: "plus", name: "Plus", monthly: 20), AgentPlan(id: "pro", name: "Pro", monthly: 200),
             AgentPlan(id: "business", name: "Business"), AgentPlan(id: "enterprise", name: "Enterprise"), .api]
        case .zcode:
            [AgentPlan(id: "lite", name: "Coding Lite", monthly: 18), AgentPlan(id: "pro", name: "Coding Pro", monthly: 72),
             AgentPlan(id: "max", name: "Coding Max", monthly: 160), AgentPlan(id: "start", name: "Start Plan"), .api]
        case .opencode:
            [AgentPlan(id: "zen", name: "OpenCode Zen"), .api]
        }
    }

    /// What the agent's own files say.
    @MainActor static func detect(_ tool: AgentMonitor.Tool) -> AgentPlan? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch tool {
        case .claude:
            // Claude Code caches the account's organization type and rate-limit tier.
            guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            guard let account = json["oauthAccount"] as? [String: Any] else {
                return json["primaryApiKey"] != nil ? detected(.api) : nil
            }
            let recorded = [account["organizationRateLimitTier"], account["userRateLimitTier"], account["organizationType"]]
                .compactMap { $0 as? String }.joined(separator: " ").lowercased()
            let id = recorded.contains("max_20x") ? "max20" : recorded.contains("max_5x") ? "max5"
                : recorded.contains("max") ? "max5" : recorded.contains("enterprise") ? "enterprise"
                : recorded.contains("team") ? "team" : recorded.contains("pro") ? "pro" : nil
            return id.flatMap { id in choices(for: .claude).first { $0.id == id } }.map(detected)
        case .codex:
            // Codex logs the ChatGPT plan with its rate limits.
            guard let type = AgentUsageStore.shared.codexPlanType?.lowercased() else { return nil }
            let id = type.contains("pro") ? "pro" : type.contains("plus") ? "plus" : type.contains("business") || type.contains("team") ? "business"
                : type.contains("enterprise") || type.contains("edu") ? "enterprise" : nil
            return id.flatMap { id in choices(for: .codex).first { $0.id == id } }.map(detected)
                ?? AgentPlan(id: type, name: type.capitalized, detected: true)
        case .zcode:
            // ZCode only records that a coding plan is connected, not its tier.
            guard let data = try? Data(contentsOf: home.appendingPathComponent(".zcode/v2/coding-plan-cache.json")),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let items = (json["entryStatus"] as? [String: Any])?["items"] as? [String: Any] else { return nil }
            func available(_ key: String) -> Bool { ((items[key] as? [String: Any])?["status"] as? String) == "available" }
            if available("builtin:zai-coding-plan") || available("builtin:bigmodel-coding-plan") {
                return AgentPlan(id: "coding", name: "GLM Coding Plan", detected: true)
            }
            if available("builtin:zai-start-plan") || available("builtin:bigmodel-start-plan") {
                return AgentPlan(id: "start", name: "Start Plan", detected: true)
            }
            return nil
        case .opencode:
            return nil
        }
    }

    private static func detected(_ plan: AgentPlan) -> AgentPlan {
        var p = plan
        p.detected = true
        return p
    }
}

// MARK: - Store

/// Token usage per hour, model and tool, kept on disk so history outlives the agents' own logs
/// (Claude Code deletes transcripts after 30 days). Claude transcripts are read incrementally;
/// Codex rollouts and the OpenCode and ZCode databases are re-read and merged hour by hour.
@MainActor
final class AgentUsageStore: ObservableObject {
    static let shared = AgentUsageStore()

    typealias Buckets = [String: [String: TokenCounts]] // hour key → model → counts

    struct Archive: Codable {
        var version = 1
        var claude: Buckets = [:]
        var claudeFiles: [String: FileState] = [:]
        var codex: Buckets = [:]
        var opencode: Buckets = [:]
        var zcode: Buckets = [:]
        var codexPlan: String?
        /// Codex's rate-limit windows from the newest rollout event that had them.
        var codexLimits: [LimitWindow]?
        /// Count and newest change of the Codex rollouts last read; unchanged means skip them.
        var codexSignature: String?
    }

    struct FileState: Codable {
        var offset: UInt64
        /// Message ids near the end of what was read, so a response split across reads counts once.
        var recentIDs: [String]
    }

    enum Period: String, CaseIterable, Identifiable {
        case today, week, month, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: "Today"
            case .week: "7 Days"
            case .month: "30 Days"
            case .all: "All Time"
            }
        }
    }

    /// A plan's rolling usage window as Codex reports it: its length, how much is used, when it resets.
    struct LimitWindow: Codable, Equatable {
        var minutes: Int
        var usedPercent: Double
        var resets: Date

        /// "5-hour", "Weekly".
        var name: String {
            minutes == 10080 ? "Weekly" : minutes > 0 && minutes % 1440 == 0 ? "\(minutes / 1440)-day" : "\(max(1, minutes / 60))-hour"
        }
    }

    /// Claude Code's 5-hour block and what was used in it so far.
    struct Block {
        let start: Date
        var end: Date { start.addingTimeInterval(5 * 3600) }
        var tokens = TokenCounts()
        var cost: Double = 0
    }

    struct ToolSummary: Identifiable {
        var id: AgentMonitor.Tool { tool }
        let tool: AgentMonitor.Tool
        var tokens = TokenCounts()
        var cost: Double = 0
        /// Tokens from models without a known price.
        var unpricedTokens = 0
    }

    struct Summary {
        var tools: [ToolSummary] = []
        var models: [(model: String, tokens: TokenCounts, cost: Double?)] = []
        /// Value per bar: hours for Today, days otherwise, oldest first.
        var series: [(label: String, cost: Double, tokens: Int)] = []
        var tokens: TokenCounts { tools.reduce(TokenCounts()) { $0 + $1.tokens } }
        var cost: Double { tools.reduce(0) { $0 + $1.cost } }
        var firstDay: Date?
    }

    @Published private(set) var archive = Archive() {
        didSet { claudeBlockStart = Self.blockStart(archive.claude) }
    }
    private var claudeBlockStart: Date?
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?

    var codexPlanType: String? { archive.codexPlan }

    private let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchApp/agent-usage.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Archive.self, from: data) {
            archive = saved
            claudeBlockStart = Self.blockStart(saved.claude)
        }
    }

    // MARK: Refresh

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let current = archive
        Task.detached(priority: .utility) {
            let updated = Self.scan(current)
            await MainActor.run {
                let store = AgentUsageStore.shared
                store.archive = updated
                store.scanning = false
                store.lastScan = Date()
                store.save()
            }
        }
    }

    private func save() {
        let snapshot = archive, file = file
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }

    func clearHistory() {
        archive = Archive()
        save()
        refresh()
    }

    nonisolated private static let hourFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH"
        return f
    }()

    nonisolated static func hourKey(_ date: Date) -> String { hourFormat.string(from: date) }
    nonisolated static func date(fromHourKey key: String) -> Date? { hourFormat.date(from: key) }

    nonisolated private static func scan(_ old: Archive) -> Archive {
        var a = old
        scanClaude(&a)
        scanCodex(&a)
        a.opencode = merged(a.opencode, scanOpenCode())
        a.zcode = merged(a.zcode, scanZCode())
        return a
    }

    /// New hours replace old ones; hours the source no longer has are kept.
    nonisolated private static func merged(_ old: Buckets, _ new: Buckets) -> Buckets {
        old.merging(new) { _, fresh in fresh }
    }

    nonisolated private static func add(_ counts: TokenCounts, model: String, at date: Date, to buckets: inout Buckets) {
        let key = hourKey(date)
        buckets[key, default: [:]][model, default: TokenCounts()] = buckets[key, default: [:]][model, default: TokenCounts()] + counts
    }

    // Claude Code: one line per message in ~/.claude/projects/*/*.jsonl, with its usage.
    nonisolated private static func scanClaude(_ a: inout Archive) {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let usageMarker = Data("\"usage\"".utf8)
        for folder in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            // Sub-agent transcripts live in nested folders; walk them too.
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                var state = a.claudeFiles[url.path] ?? FileState(offset: 0, recentIDs: [])
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                guard size != state.offset else { continue }
                if size < state.offset { state = FileState(offset: 0, recentIDs: []) } // rewritten
                try? handle.seek(toOffset: state.offset)
                let data = handle.readDataToEndOfFile()
                guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                var seen = Set(state.recentIDs)
                var order = state.recentIDs
                // Each parsed line's objects are autoreleased: drained per line, or a long history
                // (hundreds of MB of transcripts) piled up over a GB before the scan finished.
                for line in data[data.startIndex...lastNewline].split(separator: UInt8(ascii: "\n")) { autoreleasepool {
                    guard line.firstRange(of: usageMarker) != nil,
                          let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          let message = obj["message"] as? [String: Any], let u = message["usage"] as? [String: Any],
                          let model = message["model"] as? String, model != "<synthetic>" else { return }
                    let id = (message["id"] as? String) ?? (obj["requestId"] as? String) ?? UUID().uuidString
                    guard seen.insert(id).inserted else { return }
                    order.append(id)
                    let date = (obj["timestamp"] as? String).flatMap(iso.date(from:)) ?? Date()
                    let writes = u["cache_creation"] as? [String: Any]
                    let long = int(writes?["ephemeral_1h_input_tokens"])
                    let allWrites = int(u["cache_creation_input_tokens"])
                    let counts = TokenCounts(input: int(u["input_tokens"]), output: int(u["output_tokens"]),
                                             cacheRead: int(u["cache_read_input_tokens"]),
                                             cacheWrite: max(0, allWrites - long), cacheWriteLong: long, requests: 1)
                    add(counts, model: model, at: date, to: &a.claude)
                } }
                state.offset += UInt64(lastNewline - data.startIndex + 1)
                state.recentIDs = Array(order.suffix(64))
                a.claudeFiles[url.path] = state
            }
        }
    }

    // Codex: rollouts report running totals; each step's growth is that step's usage.
    nonisolated private static func scanCodex(_ a: inout Archive) {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        let newest = files.compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.max()
        let signature = "\(files.count)-\(newest?.timeIntervalSince1970 ?? 0)"
        guard signature != a.codexSignature else { return }
        a.codexSignature = signature
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var buckets: Buckets = [:]
        var plan = a.codexPlan
        var planDate = Date.distantPast
        var limits = a.codexLimits
        var limitsDate = Date.distantPast
        for url in files { autoreleasepool { // a whole rollout's parsed lines, drained per file
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            var model = "gpt-5"
            var previous = TokenCounts()
            for line in text.split(separator: "\n") where line.contains("token_count") || line.contains("turn_context") || line.contains("\"model\"") {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                let payload = obj["payload"] as? [String: Any] ?? [:]
                if let m = payload["model"] as? String, !m.isEmpty { model = m }
                guard payload["type"] as? String == "token_count" else { continue }
                let date = (obj["timestamp"] as? String).flatMap(iso.date(from:)) ?? Date()
                if let limits = payload["rate_limits"] as? [String: Any], let p = limits["plan_type"] as? String, !p.isEmpty, date > planDate {
                    plan = p
                    planDate = date
                }
                if let rates = payload["rate_limits"] as? [String: Any], date > limitsDate {
                    let windows = ["primary", "secondary"].compactMap { (rates[$0] as? [String: Any]).flatMap { limitWindow($0, at: date) } }
                    if !windows.isEmpty {
                        limits = windows
                        limitsDate = date
                    }
                }
                guard let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] else { continue }
                let cached = int(total["cached_input_tokens"])
                let now = TokenCounts(input: max(0, int(total["input_tokens"]) - cached), output: int(total["output_tokens"]),
                                      cacheRead: cached, requests: 0)
                var step = now - previous
                step.requests = step.total > 0 ? 1 : 0
                if step.total > 0 { add(step, model: model, at: date, to: &buckets) }
                previous = now
            }
        } }
        a.codex = merged(a.codex, buckets)
        a.codexPlan = plan
        a.codexLimits = limits
    }

    /// One of Codex's windows: newer builds give the reset time, older ones the seconds left.
    nonisolated private static func limitWindow(_ w: [String: Any], at date: Date) -> LimitWindow? {
        guard let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let resets: Date
        if let at = (w["resets_at"] as? NSNumber)?.doubleValue {
            resets = Date(timeIntervalSince1970: at)
        } else if let left = (w["resets_in_seconds"] as? NSNumber)?.doubleValue {
            resets = date.addingTimeInterval(left)
        } else { return nil }
        return LimitWindow(minutes: int(w["window_minutes"]), usedPercent: used, resets: resets)
    }

    nonisolated private static func scanOpenCode() -> Buckets {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
        var buckets: Buckets = [:]
        for r in AgentMonitor.query(path, """
            select json_extract(data, '$.modelID'), json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.output'),
                   json_extract(data, '$.tokens.cache.read'), json_extract(data, '$.tokens.cache.write'), time_created
            from message where json_extract(data, '$.role') = 'assistant'
            """) {
            add(TokenCounts(input: r[1].int, output: r[2].int, cacheRead: r[3].int, cacheWrite: r[4].int, requests: 1),
                model: r[0].text ?? "unknown", at: Date(timeIntervalSince1970: Double(r[5].int) / 1000), to: &buckets)
        }
        return buckets
    }

    nonisolated private static func scanZCode() -> Buckets {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcode/cli/db/db.sqlite").path
        var buckets: Buckets = [:]
        for r in AgentMonitor.query(path, """
            select model_id, input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, started_at
            from model_usage
            """) {
            // ZCode counts cached input inside input_tokens; split it out like the others.
            add(TokenCounts(input: max(0, r[1].int - r[3].int), output: r[2].int, cacheRead: r[3].int, cacheWrite: r[4].int, requests: 1),
                model: r[0].text ?? "unknown", at: Date(timeIntervalSince1970: Double(r[5].int) / 1000), to: &buckets)
        }
        return buckets
    }

    nonisolated private static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    // MARK: Summaries

    func buckets(for tool: AgentMonitor.Tool) -> Buckets {
        switch tool {
        case .claude: archive.claude
        case .codex: archive.codex
        case .opencode: archive.opencode
        case .zcode: archive.zcode
        }
    }

    func start(of period: Period, now: Date = Date()) -> Date {
        let cal = Calendar.current
        switch period {
        case .today: return cal.startOfDay(for: now)
        case .week: return cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
        case .month: return cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))!
        case .all: return .distantPast
        }
    }

    func summary(_ period: Period, now: Date = Date()) -> Summary {
        let cal = Calendar.current
        let from = start(of: period, now: now)
        let fromKey = period == .all ? "" : Self.hourKey(from)
        var s = Summary()
        var byModel: [String: TokenCounts] = [:]
        var perBar: [String: (Double, Int)] = [:]
        var earliest: String?
        for tool in AgentMonitor.Tool.allCases {
            var t = ToolSummary(tool: tool)
            for (hour, models) in buckets(for: tool) where hour >= fromKey {
                earliest = min(earliest ?? hour, hour)
                // Bars: hours today, days otherwise.
                let bar = period == .today ? String(hour.suffix(2)) : String(hour.prefix(10))
                for (model, counts) in models {
                    t.tokens = t.tokens + counts
                    byModel[model, default: TokenCounts()] = byModel[model, default: TokenCounts()] + counts
                    let c = AgentPricing.cost(counts, model: model)
                    if let c { t.cost += c } else { t.unpricedTokens += counts.total }
                    perBar[bar, default: (0, 0)].0 += c ?? 0
                    perBar[bar, default: (0, 0)].1 += counts.total
                }
            }
            if t.tokens.total > 0 { s.tools.append(t) }
        }
        s.tools.sort { $0.cost > $1.cost }
        s.models = byModel.map { ($0.key, $0.value, AgentPricing.cost($0.value, model: $0.key)) }
            .sorted { ($0.cost ?? 0, $0.tokens.total) > ($1.cost ?? 0, $1.tokens.total) }
        s.firstDay = earliest.flatMap(Self.date(fromHourKey:))
        // A full set of bars, including quiet ones.
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        switch period {
        case .today:
            let hour = cal.component(.hour, from: now)
            s.series = (0...hour).map { h in
                let key = String(format: "%02d", h)
                return (key, perBar[key]?.0 ?? 0, perBar[key]?.1 ?? 0)
            }
        default:
            let days = period == .week ? 7 : period == .month ? 30
                : max(1, min(365, (s.firstDay.map { cal.dateComponents([.day], from: cal.startOfDay(for: $0), to: now).day ?? 0 } ?? 0) + 1))
            s.series = (0..<days).reversed().map { back in
                let day = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: now))!
                let key = dayFormat.string(from: day)
                return (key, perBar[key]?.0 ?? 0, perBar[key]?.1 ?? 0)
            }
        }
        return s
    }

    // MARK: Limits

    /// The newest block's start, counted the way ccusage does: a block starts at the hour of the
    /// first message after the last one ended, and lasts five hours. Hours are enough, since
    /// blocks start on the hour.
    nonisolated private static func blockStart(_ claude: Buckets) -> Date? {
        var start: Date?
        for key in claude.keys.sorted() {
            guard let hour = date(fromHourKey: key) else { continue }
            if start.map({ hour.timeIntervalSince($0) >= 5 * 3600 }) ?? true { start = hour }
        }
        return start
    }

    /// Claude Code's block in progress, or nil when none is.
    func claudeBlock(now: Date = Date()) -> Block? {
        guard let start = claudeBlockStart else { return nil }
        var block = Block(start: start)
        guard now < block.end else { return nil }
        for h in 0..<5 {
            for (model, counts) in archive.claude[Self.hourKey(start.addingTimeInterval(Double(h) * 3600))] ?? [:] {
                block.tokens = block.tokens + counts
                block.cost += AgentPricing.cost(counts, model: model) ?? 0
            }
        }
        return block
    }

    /// Codex's windows that haven't reset yet, shortest first.
    func codexWindows(now: Date = Date()) -> [LimitWindow] {
        (archive.codexLimits ?? []).filter { $0.resets > now }.sorted { $0.minutes < $1.minutes }
    }

    /// The plan in force for a tool: chosen in Settings, else detected.
    func plan(for tool: AgentMonitor.Tool) -> AgentPlan? {
        let choice = AppSettings.shared.agentPlans[tool.rawValue] ?? ""
        if !choice.isEmpty, let p = AgentPlan.choices(for: tool).first(where: { $0.id == choice }) { return p }
        return AgentPlan.detect(tool)
    }
}

/// Time left until a date: "1h 12m", "45m", "2d 3h".
func formatTimeLeft(until date: Date, now: Date = Date()) -> String {
    let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 1440 { return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes / 1440)d \(minutes % 1440 / 60)h"
}

/// "$1,234", "$56.78", "$0.42".
func formatDollars(_ value: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.locale = Locale(identifier: "en_US")
    f.maximumFractionDigits = value >= 1000 ? 0 : 2
    f.minimumFractionDigits = value >= 1000 ? 0 : 2
    return f.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
}
