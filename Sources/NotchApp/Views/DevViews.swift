import NotchKit
import SwiftUI

// MARK: - Glances

/// Vercel beside the notch: the build ring for a push (a segment per project, filling Queued →
/// Building → Ready) and how long it's taken; otherwise a triangle in the latest deployment's colour.
struct VercelReading: View {
    var compact = false
    @ObservedObject private var vercel = VercelService.shared

    var body: some View {
        if let f = vercel.current {
            HStack(spacing: 5) {
                CIRingView(ring: f.ring, diameter: 16, style: .jobSteps)
                if !compact {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ciElapsed((f.finished ?? context.date).timeIntervalSince(f.started)))
                            .font(LiveItemView.valueFont)
                            .foregroundStyle(f.finished == nil ? .white.opacity(0.92) : CIRingView.color(f.ring.outcome))
                            .fixedSize()
                    }
                }
            }
        } else {
            let latest = vercel.recent.first
            HStack(spacing: 4) {
                Image(systemName: "triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(latest.map(Self.color) ?? .white.opacity(0.5))
                if !compact, let latest {
                    Text(GitHubResults.ago(latest.created).replacingOccurrences(of: " ago", with: ""))
                        .font(LiveItemView.valueFont).foregroundStyle(.white.opacity(0.7)).lineLimit(1).fixedSize()
                }
            }
        }
    }

    static func color(_ d: VercelService.Deployment) -> Color {
        switch d.state {
        case .ready: CIRingView.color(CIStepState.success)
        case .error: CIRingView.color(CIStepState.failure)
        case .canceled: .white.opacity(0.5)
        case .queued, .building: CIRingView.color(CIStepState.running)
        }
    }
}

/// Linear beside the notch: the issue you're on ("ENG-123"), with how many more are in progress;
/// otherwise how many are open.
struct LinearReading: View {
    var compact = false
    @ObservedObject private var linear = LinearService.shared

    var body: some View {
        if let issue = linear.inProgress.first {
            HStack(spacing: 5) {
                LinearStatusIcon(state: issue.state, size: 12)
                if !compact {
                    Text(issue.identifier).font(LiveItemView.valueFont).foregroundStyle(.white.opacity(0.92)).lineLimit(1).fixedSize()
                    if linear.inProgress.count > 1 {
                        Text("+\(linear.inProgress.count - 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).fixedSize()
                    }
                }
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "circle.dashed").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                if !compact {
                    Text("\(linear.mine.count)").font(LiveItemView.valueFont).foregroundStyle(.white.opacity(0.75)).fixedSize()
                }
            }
        }
    }
}

// MARK: - Home

/// Vercel on Home. Small: the build being followed, or the latest deployment. Medium: that, then
/// each project's latest deployment.
struct VercelCard: View {
    var small = false
    @ObservedObject private var vercel = VercelService.shared

    var body: some View {
        HomeTile {
            switch vercel.connection {
            case .off, .connecting:
                HomeNote(symbol: "triangle", text: vercel.connection == .off ? "Vercel is off" : "Signing in…")
            case .failed:
                Button { SettingsWindowController.shared.show(pane: .developer) } label: {
                    HomeNote(symbol: "key", text: "Add a Vercel token")
                }
                .buttonStyle(.plain)
            case .connected:
                VStack(alignment: .leading, spacing: 7) {
                    if let f = vercel.current { buildRow(f, ring: small ? 26 : 22) }
                    if !(small && vercel.current != nil) {
                        let projects = latestPerProject
                        if projects.isEmpty, vercel.current == nil {
                            HomeNote(symbol: "triangle", text: "No deployments yet")
                        } else {
                            ViewThatFits(in: .vertical) {
                                ForEach((1...max(1, min(small ? 2 : 5, projects.count))).reversed(), id: \.self) { n in
                                    VStack(alignment: .leading, spacing: 5) {
                                        ForEach(projects.prefix(n)) { d in row(d) }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: small ? .center : .top)
            }
        }
    }

    private var latestPerProject: [VercelService.Deployment] {
        var seen = Set<String>()
        return vercel.recent.filter { seen.insert($0.project).inserted }
    }

    private func buildRow(_ f: VercelService.Followed, ring: CGFloat) -> some View {
        Button { if let u = f.url { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: 8) {
                CIRingView(ring: f.ring, diameter: ring, style: .jobSteps)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.title).font(HomeType.row.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let time = ciElapsed((f.finished ?? context.date).timeIntervalSince(f.started))
                        Text(f.finished == nil ? "\(f.ring.jobsDone)/\(f.ring.jobsTotal) · \(time)"
                             : f.ring.outcome == .failed ? "Failed · \(time)" : "Ready · \(time)")
                            .font(HomeType.detail)
                            .foregroundStyle(f.finished == nil ? HomeType.secondary : CIRingView.color(f.ring.outcome))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ d: VercelService.Deployment) -> some View {
        Button { if let u = d.state == .ready ? d.url : d.inspector { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: 6) {
                DeployMark(d: d, size: 11).frame(width: 12)
                Text(d.project).font(HomeType.row).foregroundStyle(.white.opacity(0.82))
                Spacer(minLength: 2)
                Text(GitHubResults.ago(d.created).replacingOccurrences(of: " ago", with: ""))
                    .font(HomeType.detail).foregroundStyle(HomeType.secondary)
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(d.project) · \(d.label) · \(d.branch ?? "") · \(d.state.rawValue)")
    }
}

/// Linear on Home. Small: the issue you're on. Medium: your open issues, in progress first.
struct LinearCard: View {
    var small = false
    @ObservedObject private var linear = LinearService.shared

    var body: some View {
        HomeTile {
            switch linear.connection {
            case .off, .connecting:
                HomeNote(symbol: "circle.lefthalf.filled", text: linear.connection == .off ? "Linear is off" : "Signing in…")
            case .failed:
                Button { SettingsWindowController.shared.show(pane: .developer) } label: {
                    HomeNote(symbol: "key", text: "Add a Linear key")
                }
                .buttonStyle(.plain)
            case .connected:
                if linear.mine.isEmpty {
                    HomeNote(symbol: "checkmark.circle", text: "No open issues")
                } else if small {
                    let issue = linear.inProgress.first ?? linear.mine[0]
                    Button { linear.open(issue) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                LinearStatusIcon(state: issue.state, size: 11)
                                Text(issue.identifier).font(HomeType.label).foregroundStyle(HomeType.secondary)
                            }
                            Text(issue.title).font(HomeType.row.weight(.medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                        }
                        .frame(maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    ViewThatFits(in: .vertical) {
                        ForEach((1...min(5, linear.mine.count)).reversed(), id: \.self) { n in
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(linear.mine.prefix(n)) { issue in
                                    Button { linear.open(issue) } label: {
                                        HStack(spacing: 6) {
                                            LinearStatusIcon(state: issue.state, size: 10).frame(width: 12)
                                            Text(issue.title).font(HomeType.row).foregroundStyle(.white.opacity(issue.started ? 0.92 : 0.72))
                                            Spacer(minLength: 0)
                                        }
                                        .lineLimit(1)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("\(issue.identifier) · \(issue.state.name) · \(issue.title)")
                                }
                                if linear.mine.count > n {
                                    Text("+\(linear.mine.count - n) more").font(HomeType.detail).foregroundStyle(HomeType.secondary).padding(.leading, 18)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
