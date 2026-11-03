import NotchKit
import SwiftUI

/// The Actions ring: one segment per step, in order around the circle from the top. Green when a
/// step passed, yellow (breathing) while it runs, red when it failed, grey while it waits.
struct CIRingView: View {
    let ring: CIRing
    var diameter: CGFloat = 18
    var lineWidth: CGFloat? = nil
    /// One segment per job (as GitHub counts checks), each filling with its steps; false draws one
    /// segment per step (a pull request's checks, already one each).
    var byJob = true

    var body: some View {
        let line = lineWidth ?? max(2, (diameter / 8 * 2).rounded() / 2)
        let groups: [[CIRing.Step]] = byJob ? ring.jobs.map(\.steps) : ring.steps.map { [$0] }
        let count = max(groups.count, 1)
        // A hairline gap between segments while there's room for it.
        let gap = count > 1 && count < 40 ? min(0.012, 0.25 / Double(count)) : 0
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: line)
            if ring.steps.isEmpty {
                // Actions hasn't listed any jobs yet: a quarter turning while it starts.
                TimelineView(.animation) { context in
                    Circle().trim(from: 0, to: 0.22)
                        .stroke(CIRingView.color(CIStepState.running), style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                }
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { i, steps in
                    // The job's share of the circle, split evenly between its steps.
                    let from = Double(i) / Double(count) + gap / 2, to = Double(i + 1) / Double(count) - gap / 2
                    let each = (to - from) / Double(max(steps.count, 1))
                    ForEach(Array(steps.enumerated()), id: \.offset) { j, step in
                        Segment(from: from + Double(j) * each, to: from + Double(j + 1) * each, state: step.state, line: line)
                    }
                }
            }
        }
        .rotationEffect(.degrees(-90))
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.35), value: ring)
    }

    static func color(_ state: CIStepState) -> Color {
        switch state {
        case .success: Color(red: 0.25, green: 0.82, blue: 0.4)
        case .running: Color(red: 1, green: 0.8, blue: 0.2)
        case .failure: Color(red: 1, green: 0.3, blue: 0.3)
        case .cancelled, .skipped: .white.opacity(0.32)
        case .queued: .white.opacity(0.0)
        }
    }

    static func color(_ outcome: CIRing.Outcome) -> Color {
        switch outcome {
        case .passed: color(CIStepState.success)
        case .failed: color(CIStepState.failure)
        case .running: color(CIStepState.running)
        case .cancelled: .white.opacity(0.5)
        }
    }

    private struct Segment: View {
        let from: Double
        let to: Double
        let state: CIStepState
        let line: CGFloat
        @State private var dim = false

        var body: some View {
            Circle().trim(from: from, to: max(from, to))
                .stroke(CIRingView.color(state), style: StrokeStyle(lineWidth: line, lineCap: .butt))
                .opacity(state == .running && dim ? 0.45 : 1)
                .onAppear { breathe() }
                .onChange(of: state) { _, _ in breathe() }
        }

        private func breathe() {
            guard state == .running else { dim = false; return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

/// "1:42", "12:05", "1:02:10".
func ciElapsed(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// The GitHub Glance: the Actions ring and how long it's been going while a push is followed;
/// otherwise how many things wait on you.
struct GitHubReading: View {
    var compact = false
    @ObservedObject private var github = GitHubService.shared

    var body: some View {
        if let run = github.currentRun {
            HStack(spacing: 5) {
                CIRingView(ring: run.ring, diameter: 16)
                if !compact {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ciElapsed((run.finished ?? context.date).timeIntervalSince(run.started)))
                            .font(LiveItemView.valueFont)
                            .foregroundStyle(run.finished == nil ? .white.opacity(0.92) : CIRingView.color(run.ring.outcome))
                            .fixedSize()
                    }
                }
            }
        } else {
            let count = github.needsYouCount
            HStack(spacing: 4) {
                if !compact || count == 0 {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(count > 0 ? 0.85 : 0.5))
                }
                if count > 0 || !compact {
                    Text("\(count)")
                        .font(LiveItemView.valueFont)
                        .foregroundStyle(count > 0 ? .white : .white.opacity(0.5))
                        .rollingDigits(count)
                        .fixedSize()
                }
            }
        }
    }
}

/// GitHub on Home. Small: the run being followed, or how many reviews wait on you. Medium: that,
/// then review requests and your pull requests with their checks.
struct GitHubCard: View {
    var small = false
    @ObservedObject private var github = GitHubService.shared

    var body: some View {
        HomeTile {
            switch github.connection {
            case .off, .connecting:
                HomeNote(symbol: "arrow.triangle.pull", text: github.connection == .off ? "GitHub is off" : "Signing in…")
            case .failed:
                Button { SettingsWindowController.shared.show(pane: .developer) } label: {
                    HomeNote(symbol: "person.crop.circle.badge.exclamationmark", text: "Sign in to GitHub")
                }
                .buttonStyle(.plain)
            case .connected:
                if small { smallBody } else { mediumBody }
            }
        }
    }

    @ViewBuilder private var smallBody: some View {
        if let run = github.currentRun {
            runRow(run, ring: 26)
                .frame(maxHeight: .infinity)
        } else {
            let count = github.needsYouCount
            Button { github.openTop() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count)").font(HomeType.figure).rollingNumber(count)
                    Text(count == 1 ? "waiting on you" : count == 0 ? "Nothing waiting" : "waiting on you")
                        .font(HomeType.label).foregroundStyle(HomeType.secondary)
                }
                .frame(maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var mediumBody: some View {
        let pulls = github.pulls
        return VStack(alignment: .leading, spacing: 7) {
            if let run = github.currentRun { runRow(run, ring: 22) }
            if pulls.isEmpty {
                if github.currentRun == nil { HomeNote(symbol: "checkmark.circle", text: "No open pull requests") }
            } else {
                ViewThatFits(in: .vertical) {
                    ForEach((1...min(5, pulls.count)).reversed(), id: \.self) { count in
                        list(Array(pulls.prefix(count)), more: pulls.count - count)
                    }
                }
            }
        }
    }

    private func runRow(_ run: GitHubService.FollowedRun, ring: CGFloat) -> some View {
        Button { NSWorkspace.shared.open(run.url) } label: {
            HStack(spacing: 8) {
                CIRingView(ring: run.ring, diameter: ring)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.branch).font(HomeType.row.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(status(run, now: context.date))
                            .font(HomeType.detail)
                            .foregroundStyle(run.finished == nil ? HomeType.secondary : CIRingView.color(run.ring.outcome))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(run.repo) · \(run.title)")
    }

    private func status(_ run: GitHubService.FollowedRun, now: Date) -> String {
        let time = ciElapsed((run.finished ?? now).timeIntervalSince(run.started))
        if run.finished != nil {
            return switch run.ring.outcome {
            case .passed, .running: "Passed · \(time)"
            case .failed: "Failed · \(time)"
            case .cancelled: "Cancelled"
            }
        }
        guard run.ring.total > 0 else { return "Starting…" }
        return "\(run.ring.jobsDone)/\(run.ring.jobsTotal) · \(time)"
    }

    private func list(_ pulls: [GitHubService.PullRequest], more: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(pulls) { pr in
                Button { github.open(pr) } label: {
                    HStack(spacing: 6) {
                        mark(pr).frame(width: 12)
                        Text(pr.title)
                            .font(HomeType.row)
                            .foregroundStyle(.white.opacity(pr.draft ? 0.5 : 0.82))
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(pr.repo)#\(pr.number) · \(pr.title)\(pr.wantsReview ? " · wants your review" : "")")
            }
            if more > 0 {
                Text("+\(more) more").font(HomeType.detail).foregroundStyle(HomeType.secondary).padding(.leading, 18)
            }
        }
    }

    /// An eye for a review waiting on you; else a dot in the colour of the checks.
    @ViewBuilder private func mark(_ pr: GitHubService.PullRequest) -> some View {
        if pr.wantsReview {
            Image(systemName: "eye.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
        } else {
            let color: Color = switch pr.checks {
            case .passed: CIRingView.color(CIStepState.success)
            case .failed: CIRingView.color(CIStepState.failure)
            case .pending: CIRingView.color(CIStepState.running)
            case .none: .white.opacity(0.3)
            }
            Circle().fill(color).frame(width: 6, height: 6)
        }
    }
}
