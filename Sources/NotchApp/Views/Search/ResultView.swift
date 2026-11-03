import SwiftUI

struct ResultView: View {
    let job: AssistantStore.Job
    let accent: Color
    @Binding var excluded: Set<UUID>
    @Binding var selection: Int
    let applyPlan: (CommandPlanner.Plan) -> Void
    @EnvironmentObject private var assistant: AssistantStore

    var body: some View {
        switch job.state {
        case _ where job.meeting != nil:
            MeetingResults(job: job, id: job.meeting!, accent: accent)
        case .running where job.route == .web && !(job.answer ?? "").isEmpty:
            // The answer streams in as it's written.
            WebResults(job: job, accent: accent, selection: $selection)
        case .running where job.route == .screen && !(job.answer ?? "").isEmpty:
            ScreenResults(job: job, accent: accent, selection: $selection)
        case .running where job.route == .help && !(job.answer ?? "").isEmpty:
            HelpResults(job: job, accent: accent, selection: $selection)
        case .running(let stage):
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                // Not sure where to look yet: the sparkle glass, until it is.
                SearchingCapsule(icon: job.route?.icon ?? "sparkle.magnifyingglass", tint: job.route?.tint)
                    .padding(.bottom, 6)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                ShimmerText(text: stage)
                Text(job.route == .web ? "Searching the web" : job.route == .files ? "Searching your Mac"
                     : job.route == .weather ? "Getting the weather" : job.route == .actions ? "Turning that into actions"
                     : job.route == .calendar ? "Reading your calendar"
                     : job.route == .notes ? "Looking in your notes"
                     : job.route == .screen ? ScreenQuestion.privacyLine
                     : job.route == .help ? "From NotchApp's guide, settings and changelog"
                     : job.route == .recall ? "Looking through what you've seen, on this Mac"
                     : job.route == .github ? "Asking GitHub"
                     : "Working out where to look")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 20))
                Text(message).font(.system(size: 12)).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    // Straight to the right list: "Screen Recording" is easy to confuse with Accessibility.
                    if job.route == .screen, !ScreenQuestion.hasPermission {
                        Button("Open Screen Recording settings") { ScreenQuestion.openPrivacySettings() }
                            .buttonStyle(NotchPillButtonStyle())
                    }
                    Button("Try again") { assistant.run(job.query, route: job.route) }
                        .buttonStyle(NotchPillButtonStyle(primary: true))
                }
            }
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done where job.route == .actions:
            if let plan = job.plan { PlanView(plan: plan, excluded: $excluded, apply: applyPlan) }
        case .done where job.route == .app:
            AppPicksView(job: job, selection: $selection)
        case .done:
            VStack(spacing: 10) {
                switch job.route {
                case .files?: FileResults(job: job, accent: accent, selection: $selection)
                case .weather?: if let report = job.weather { WeatherCard(report: report, accent: accent) }
                case .github?: if let answer = job.github { GitHubResults(answer: answer, selection: $selection) }
                case .calendar?: if let answer = job.calendar { CalendarResult(answer: answer) }
                case .notes?: if let answer = job.notes { NotesResult(answer: answer) }
                case .screen?: ScreenResults(job: job, accent: accent, selection: $selection)
                case .help?: HelpResults(job: job, accent: accent, selection: $selection)
                case .recall?: if let answer = job.recall { RecallResults(answer: answer, selection: $selection) }
                default: WebResults(job: job, accent: accent, selection: $selection)
                }
                RouteFooter(job: job)
            }
        }
    }
}

/// "Do it in this app" when it wasn't sure, or the pick would delete or close something: the best
/// match and alternatives, to run with a click (or ↩ on the highlighted one).
private struct AppPicksView: View {
    let job: AssistantStore.Job
    @Binding var selection: Int
    @EnvironmentObject private var assistant: AssistantStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold))
                Text(AppDo.isRisky(job.appPicks.first!) ? "Check this one first, in \(job.appName ?? "the app")"
                     : "Did you mean, in \(job.appName ?? "the app")")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            VStack(spacing: 4) {
                ForEach(Array(job.appPicks.enumerated()), id: \.offset) { i, pick in
                    Button { assistant.runAppPick(pick) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pick.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 20)
                                .foregroundStyle(.white.opacity(0.8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pick.title).font(.system(size: 13, weight: .semibold))
                                if let sub = pick.subtitle {
                                    Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                }
                            }
                            Spacer()
                            if i == selection {
                                Text(AppDo.isRisky(pick) ? "Run anyway" : "Run")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AppDo.isRisky(pick) ? .orange : .white.opacity(0.8))
                                KeyCap(text: "↩")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(.white.opacity(i == selection ? 0.12 : 0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { selection = i } }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RouteFooter: View {
    let job: AssistantStore.Job
    @EnvironmentObject private var assistant: AssistantStore

    /// Where the answer came from.
    private var source: (icon: String, text: String) {
        switch job.route {
        case .files?: ("internaldrive", "Searched your Mac")
        case .weather?: ("cloud.sun", "Open-Meteo forecast")
        case .calendar?: ("calendar", job.calendar?.tasks.isEmpty == false ? "Your calendar and tasks" : "Your calendar")
        case .notes?: ("note.text", "Your notes and tasks")
        case .screen?: ("macwindow", job.screenIsArea ? (job.sources.isEmpty ? "Looked at the area" : "The area and the web")
                        : job.sources.isEmpty ? "Looked at your screen" : "Your screen and the web")
        case .help?: ("questionmark.circle", "NotchApp help")
        case .recall?: ("clock.arrow.circlepath", "Recall, on this Mac")
        case .github?: ("arrow.triangle.pull", GitHubService.shared.connection.login.map { "GitHub, as \($0)" } ?? "GitHub")
        case .write?: ("character.bubble", "Written by \(!AppSettings.shared.aiProvider.isCloud ? "the model on this Mac" : AppSettings.shared.aiProvider.shortName)")
        default: ("globe", "Searched the web")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: source.icon)
                .foregroundStyle(job.route?.tint ?? .white.opacity(0.5))
            Text(source.text)
            // With a list showing, its header says this instead.
            if job.findingMore, job.files.count < 2 {
                Text("·")
                SearchingCapsule(height: 9)
                Text("finding more")
                    .transition(.opacity)
            }
            // What an action wrote (a summary, a drafted reply) is for copying; searching the web for
            // its hidden instruction instead wouldn't mean anything.
            // What to do next, as buttons rather than faint links: the suggested next step in the
            // accent colour, the others plain, so they read over the glass and anything behind it.
            if let next = job.followUpTitle, job.state == .done {
                Button(next) { assistant.runFollowUp() }
                    .buttonStyle(NotchPillButtonStyle(primary: true, height: 20))
                    .padding(.leading, 4)
            }
            if ChatStore.canContinue(job) {
                Button("Follow up") { ChatWindow.shared.open(from: job) }
                    .buttonStyle(NotchPillButtonStyle(primary: job.followUpTitle == nil, height: 20))
                    .padding(.leading, job.followUpTitle == nil ? 4 : 0)
                    .help("Keep talking about this answer in a chat window (⌘↩). Type a follow-up first to ask it there.")
            }
            if job.route == .write || job.actionTitle != nil, let answer = job.answer, job.state == .done {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                    Haptics.tap()
                }
                .buttonStyle(NotchPillButtonStyle(height: 20))
            } else if job.route != .calendar, job.actionTitle == nil {
                Button(job.route == .web || job.route == .notes ? "Search my files instead" : "Search the web instead") {
                    assistant.switchRoute()
                }
                .buttonStyle(NotchPillButtonStyle(height: 20))
                .padding(.leading, (job.followUpTitle == nil || job.state != .done) && !ChatStore.canContinue(job) ? 4 : 0)
            }
            Spacer()
            if !assistant.aiAvailable && job.route != .weather && job.route != .recall && job.route != .github && assistant.pullingModel == nil {
                Text(job.route == .web ? "AI writes answers from these ·" : "AI picks the best match ·")
                if case .modelMissing = assistant.status { DownloadModelMenu() }
            } else if job.route == .recall, !(job.recall?.hits.isEmpty ?? true) {
                KeyHints(hints: [("↑↓", nil), ("↩", "open"), ("⌘Y", "preview")])
            } else if job.route == .github, let links = job.github?.links, !links.isEmpty {
                KeyHints(hints: links.count > 1 ? [("↑↓", nil), ("↩", "open")] : [("↩", "open")])
            } else if job.route == .files, !job.files.isEmpty {
                KeyHints(hints: job.files.count > 1 ? [("↑↓", nil), ("↩", "open"), ("⌘Y", "preview")]
                                                    : [("↩", "open"), ("⌘Y", "preview")])
            } else if job.route != .weather && job.route != .calendar && !job.sources.isEmpty {
                KeyHints(hints: [("↑↓", nil), ("↩", "open")])
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
    }
}

/// Small keycaps with what each does, for the keyboard shortcuts over results.
private struct KeyHints: View {
    let hints: [(key: String, action: String?)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(hints, id: \.key) { hint in
                HStack(spacing: 3) {
                    KeyCap(text: hint.key)
                    if let action = hint.action { Text(action) }
                }
            }
        }
    }
}
