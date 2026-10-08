import SwiftUI

/// Agents tab: coding-agent sessions (working, waiting for you, idle) with ways to jump to them,
/// and today's token usage per tool.
enum AgentsPane: String {
    case sessions, usage
    static let options: [(value: AgentsPane, title: String)] = [(.sessions, "Sessions"), (.usage, "Usage")]
}

/// Agents tab: live sessions (working, waiting for you, idle) with ways to jump to them, and
/// usage over time: tokens, what they'd cost on the API, and how that compares with your plans.
struct AgentsView: View {
    @EnvironmentObject private var agents: AgentMonitor
    @ObservedObject private var store = AgentUsageStore.shared
    @AppStorage("agents.pane") private var pane: AgentsPane = .sessions
    @AppStorage("agents.period") private var period: AgentUsageStore.Period = .today

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PaneSwitcher(selection: $pane, options: AgentsPane.options)
                if pane == .sessions {
                    if !agents.working.isEmpty { Badge(text: "\(agents.working.count) working", color: .green) }
                    if !agents.waiting.isEmpty { Badge(text: "\(agents.waiting.count) waiting", color: .orange) }
                }
                Spacer()
                if pane == .usage {
                    if store.scanning { ProgressView().controlSize(.mini).tint(.white) }
                    PeriodPicker(period: $period)
                }
            }
            Group {
                switch pane {
                case .sessions:
                    HStack(spacing: 10) {
                        SessionsList()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        TodayCard { pane = .usage }
                            .frame(width: 222)
                    }
                case .usage:
                    UsagePane(period: period)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { agents.viewerAppeared() }
        .onDisappear { agents.viewerDisappeared() }
    }
}

private struct PeriodPicker: View {
    @Binding var period: AgentUsageStore.Period

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AgentUsageStore.Period.allCases) { p in
                Button { withAnimation(.easeOut(duration: 0.15)) { period = p } } label: {
                    Text(p.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(period == p ? 0.95 : 0.45))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(.white.opacity(period == p ? 0.14 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
    }
}

private struct SessionsList: View {
    @EnvironmentObject private var agents: AgentMonitor

    var body: some View {
        if agents.sessions.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 18))
                Text(agents.installed.isEmpty ? "No coding agents found on this Mac" : "No agent sessions in the last hour")
                    .font(.system(size: 11.5, weight: .medium))
                Text("Claude Code, Codex, OpenCode and ZCode show up here")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(agents.sessions) { SessionRow(session: $0) }
                }
            }
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// The tool's mark: its glyph on its color.
struct AgentGlyph: View {
    let tool: AgentMonitor.Tool
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: tool.glyph)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(tool == .opencode ? Color.black : .white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tool.tint.gradient))
    }
}

private struct SessionRow: View {
    let session: AgentMonitor.Session
    @EnvironmentObject private var agents: AgentMonitor
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            AgentGlyph(tool: session.tool)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.project).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if hovering {
                actions
            } else {
                status
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { agents.focus(session) }
        .help(session.directory ?? session.title)
    }

    private var subtitle: String {
        var parts = [session.tool.name]
        if session.project != session.title { parts.append(session.title) }
        if let model = session.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        switch session.state {
        case .working:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(.green)
                Text("Working").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
            }
        case .waiting:
            Label("Needs you", systemImage: "hand.raised.fill")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
        case .idle:
            Text(session.updated.formatted(.relative(presentation: .named)))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button { agents.focus(session) } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(NotchIconButtonStyle(size: 22))
            .help(session.pid != nil ? "Go to its terminal" : "Open \(session.tool.name)")
            if session.directory != nil {
                Button { agents.openFolder(session) } label: {
                    Image(systemName: "folder").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(NotchIconButtonStyle(size: 22))
                .help("Show the project in Finder")
            }
            if session.pid != nil, session.state == .working {
                Button { agents.interrupt(session) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(NotchIconButtonStyle(size: 22))
                .help("Interrupt (like pressing Esc/Ctrl-C)")
            }
        }
    }
}

/// Today at a glance beside the sessions: API value, tokens, the hour-by-hour shape.
private struct TodayCard: View {
    let showUsage: () -> Void
    @ObservedObject private var store = AgentUsageStore.shared

    var body: some View {
        let s = store.summary(.today)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "chart.bar.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.purple)
                Text("Today").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("\(formatTokens(s.tokens.total)) tokens").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatDollars(s.cost))
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .rollingNumber(formatDollars(s.cost))
                Text("API value").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            }
            ValueBars(series: s.series.map(\.cost), highlightLast: true)
                .frame(height: 22)
            VStack(spacing: 3) {
                ForEach(s.tools.prefix(3)) { t in
                    HStack(spacing: 6) {
                        AgentGlyph(tool: t.tool, size: 12)
                        Text(t.tool.name).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(formatDollars(t.cost)).font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [Color.purple.opacity(0.1), .white.opacity(0.035)], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: showUsage)
        .help("Click for usage history")
    }
}

/// Usage over a period: the API value of everything the agents did, a bar per hour or day, and
/// each tool with its plan, its share and how far the plan goes.
private struct UsagePane: View {
    let period: AgentUsageStore.Period
    @ObservedObject private var store = AgentUsageStore.shared
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let s = store.summary(period)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(formatDollars(s.cost))
                        .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                        .rollingNumber(formatDollars(s.cost))
                    Text("API value").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                }
                Text(subtitle(s))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                ValueBars(series: s.series.map(\.cost), highlightLast: true, labels: barLabels(s))
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 250)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color.purple.opacity(0.12), .white.opacity(0.035)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1))
            .help(topModels(s))

            if s.tools.isEmpty {
                Text(store.scanning ? "Reading agent logs…" : "No agent usage in this period")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(s.tools) { t in
                            ToolUsageRow(summary: t, plan: store.plan(for: t.tool), period: period,
                                         share: s.cost > 0 ? t.cost / s.cost : 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func subtitle(_ s: AgentUsageStore.Summary) -> String {
        var parts = ["\(formatTokens(s.tokens.total)) tokens", "\(s.tokens.requests.formatted()) requests"]
        if period == .all, let first = s.firstDay { parts.append("since " + (Calendar.current.isDate(first, equalTo: Date(), toGranularity: .year)
            ? first.formatted(.dateTime.month(.abbreviated).day()) : first.formatted(.dateTime.month(.abbreviated).day().year()))) }
        return parts.joined(separator: " · ")
    }

    private func barLabels(_ s: AgentUsageStore.Summary) -> (String, String)? {
        guard let first = s.series.first?.label, s.series.count > 1 else { return nil }
        switch period {
        case .today: return ("\(first):00", "now")
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            let start = f.date(from: first).map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? first
            return (start, "today")
        }
    }

    private func topModels(_ s: AgentUsageStore.Summary) -> String {
        s.models.prefix(6).map { "\($0.model): \(formatTokens($0.tokens.total)) · \($0.cost.map(formatDollars) ?? "no price")" }
            .joined(separator: "\n")
    }
}

/// One tool: its plan, tokens and API value, and against a monthly plan, how many times over it paid off.
private struct ToolUsageRow: View {
    let summary: AgentUsageStore.ToolSummary
    let plan: AgentPlan?
    let period: AgentUsageStore.Period
    let share: Double

    var body: some View {
        HStack(spacing: 9) {
            AgentGlyph(tool: summary.tool, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(summary.tool.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    if let plan { PlanBadge(plan: plan) }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(summary.tool.tint.gradient).frame(width: max(3, geo.size.width * share))
                    }
                }
                .frame(height: 4)
                Text(detail).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatDollars(summary.cost)).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                if let roi { Text(roi).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.green) }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
        .help(summary.unpricedTokens > 0 ? "\(formatTokens(summary.unpricedTokens)) tokens from models without a public price (local models) aren't counted" : "")
    }

    private var detail: String {
        let t = summary.tokens
        return "\(formatTokens(t.total)) tokens · \(formatTokens(t.output)) out · \(formatTokens(t.cacheRead)) cached"
    }

    /// Value against the plan's price over the same span: "6.2× plan" for 30 days.
    private var roi: String? {
        guard let monthly = plan?.monthly, monthly > 0, !(plan?.isAPI ?? true) else { return nil }
        let months: Double = switch period {
        case .today: 1 / 30
        case .week: 7 / 30
        case .month: 1
        case .all: 0
        }
        guard months > 0 else { return nil }
        let ratio = summary.cost / (monthly * months)
        return ratio >= 0.1 ? String(format: ratio >= 10 ? "%.0f× plan" : "%.1f× plan", ratio) : nil
    }
}

struct PlanBadge: View {
    let plan: AgentPlan

    var body: some View {
        Text(plan.monthly.map { "\(plan.name) · $\(Int($0))/mo" } ?? plan.name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(plan.isAPI ? Color.orange : .white.opacity(0.75))
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(Capsule().fill(plan.isAPI ? Color.orange.opacity(0.15) : .white.opacity(0.1)))
            .help(plan.detected ? "Found in the agent's settings" : "Chosen in Settings › Agents")
    }
}

/// Bars of dollar value, oldest first; optional start and end labels underneath.
private struct ValueBars: View {
    let series: [Double]
    var highlightLast = false
    var labels: (String, String)? = nil

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let peak = series.max() ?? 0
                let gap: CGFloat = series.count > 40 ? 1 : 2
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(series.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(highlightLast && i == series.count - 1 ? Color.purple : Color.purple.opacity(0.55))
                            .frame(height: peak > 0 ? max(1.5, geo.size.height * series[i] / peak) : 1.5)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            if let labels {
                HStack {
                    Text(labels.0)
                    Spacer()
                    Text(labels.1)
                }
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}
