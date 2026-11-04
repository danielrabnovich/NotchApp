import NotchKit
import SwiftUI

/// GitHub in Search: one pull request with its checks as a ring, a list of pull requests or
/// issues, or recent Actions runs. ↑↓ and ↩ go through the rows.
struct GitHubResults: View {
    let answer: GitHubAnswer
    @Binding var selection: Int
    /// A narrow place (a chat): a pull request's checks aren't listed beside it.
    var narrow = false

    var body: some View {
        if let pull = answer.pull {
            PullCard(pull: pull, narrow: narrow)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(answer.headline).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let detail = answer.detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
                if answer.items.isEmpty && answer.runs.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.white.opacity(0.4))
                        Text("Nothing here").foregroundStyle(.white.opacity(0.5))
                    }
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 2) {
                                ForEach(Array(answer.items.enumerated()), id: \.element.id) { i, item in
                                    ItemRow(item: item, selected: i == selection).id(i)
                                        .onTapGesture {
                                            if answer.choices { AssistantStore.shared.run("\(item.repo)#\(item.number)", route: .github) }
                                            else { NSWorkspace.shared.open(item.url) }
                                        }
                                        .onHover { if $0 { selection = i } }
                                }
                                ForEach(Array(answer.runs.enumerated()), id: \.element.id) { i, run in
                                    RunRow(run: run, selected: i == selection).id(i)
                                        .onTapGesture { NSWorkspace.shared.open(run.url) }
                                        .onHover { if $0 { selection = i } }
                                }
                            }
                        }
                        .onChange(of: selection) { _, i in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i) } }
                    }
                }
            }
        }
    }

    static func color(_ state: GitHubAnswer.Pull.State) -> Color {
        switch state {
        case .open: Color(red: 0.25, green: 0.78, blue: 0.4)
        case .draft: .white.opacity(0.5)
        case .merged: Color(red: 0.65, green: 0.5, blue: 1)
        case .closed: Color(red: 1, green: 0.38, blue: 0.38)
        }
    }

    static func icon(_ state: GitHubAnswer.Pull.State, pull: Bool) -> String {
        switch state {
        case .open: pull ? "arrow.triangle.pull" : "smallcircle.filled.circle"
        case .draft: "pencil.circle"
        case .merged: "arrow.triangle.merge"
        case .closed: pull ? "xmark.circle" : "checkmark.circle"
        }
    }

    static func ago(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// One pull request in full: its checks as the Actions ring, where it stands, and what to do.
private struct PullCard: View {
    let pull: GitHubAnswer.Pull
    let narrow: Bool
    @State private var copied: String?
    @State private var rerun: Bool?

    var body: some View {
        // The checks beside it in Search; a chat has room for the ring and the rest only.
        HStack(alignment: .top, spacing: 22) {
            main.frame(maxWidth: .infinity, alignment: .leading)
            if !narrow, !pull.checks.steps.isEmpty { checkList.frame(width: 220) }
        }
    }

    private var main: some View {
            HStack(alignment: .top, spacing: 16) {
                ring
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(pull.repo).foregroundStyle(.white.opacity(0.5))
                        Text("#\(pull.number)").foregroundStyle(.white.opacity(0.35)).monospacedDigit()
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    Text(pull.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        statePill
                        Text("\(pull.head) → \(pull.base)").lineLimit(1).truncationMode(.middle)
                        if !pull.author.isEmpty { Text("· \(pull.author)").lineLimit(1) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    HStack(spacing: 8) {
                        Text("+\(pull.additions)").foregroundStyle(Color(red: 0.3, green: 0.82, blue: 0.45))
                        Text("−\(pull.deletions)").foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                        Text("\(pull.files) file\(pull.files == 1 ? "" : "s")")
                        if pull.comments > 0 { Text("\(pull.comments) comment\(pull.comments == 1 ? "" : "s")") }
                        if let review { Text(review.text).foregroundStyle(review.color) }
                        if pull.mergeable == false, pull.state == .open || pull.state == .draft { Text("Conflicts").foregroundStyle(.orange) }
                    }
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 4)
                    buttons
                }
            }
    }

    private var ring: some View {
        ZStack {
            CIRingView(ring: pull.checks, diameter: 62, lineWidth: 6)
                .opacity(pull.checks.steps.isEmpty ? 0.4 : 1)
            VStack(spacing: 0) {
                switch pull.checks.steps.isEmpty ? nil : pull.checks.outcome {
                case .passed?: Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundStyle(CIRingView.color(.passed))
                case .failed?: Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).foregroundStyle(CIRingView.color(.failed))
                case .cancelled?: Image(systemName: "stop.fill").font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                case .running?:
                    Text("\(pull.checks.jobsDone)/\(pull.checks.jobsTotal)").font(.system(size: 14, weight: .semibold).monospacedDigit())
                case nil:
                    Image(systemName: GitHubResults.icon(pull.state, pull: true))
                        .font(.system(size: 20, weight: .medium)).foregroundStyle(GitHubResults.color(pull.state))
                }
            }
        }
        .frame(width: 62, height: 62)
        .help(pull.checks.steps.isEmpty ? "No checks" : "\(pull.checks.done) of \(pull.checks.total) checks done")
    }

    private var statePill: some View {
        HStack(spacing: 3) {
            Image(systemName: GitHubResults.icon(pull.state, pull: true)).font(.system(size: 9, weight: .bold))
            Text(pull.state.rawValue.capitalized).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(GitHubResults.color(pull.state))
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(Capsule().fill(GitHubResults.color(pull.state).opacity(0.16)))
    }

    private var review: (text: String, color: Color)? {
        switch pull.review {
        case "APPROVED": ("Approved", Color(red: 0.3, green: 0.82, blue: 0.45))
        case "CHANGES_REQUESTED": ("Changes requested", .orange)
        case "REVIEW_REQUIRED": ("Review required", .white.opacity(0.55))
        default: nil
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("Open") { NSWorkspace.shared.open(pull.url) }
                .buttonStyle(NotchPillButtonStyle(primary: true))
            Button(copied == "link" ? "Copied" : "Copy Link") { copy(pull.url.absoluteString, as: "link") }
                .buttonStyle(NotchPillButtonStyle())
            if pull.state == .open || pull.state == .draft {
                Button(copied == "checkout" ? "Copied" : "Copy Checkout") { copy("gh pr checkout \(pull.number) -R \(pull.repo)", as: "checkout") }
                    .buttonStyle(NotchPillButtonStyle())
                    .help("gh pr checkout \(pull.number) -R \(pull.repo)")
            }
            if pull.checks.hasFailure, !pull.runIDs.isEmpty, pull.checks.outcome != .running {
                Button(rerun == true ? "Re-running" : rerun == false ? "Couldn't" : "Re-run Failed") {
                    Task { rerun = await GitHubSearch.rerunFailed(pull) }
                }
                .buttonStyle(NotchPillButtonStyle())
                .disabled(rerun != nil)
            }
        }
    }

    private func copy(_ text: String, as key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Haptics.tap()
        copied = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == key { copied = nil } }
    }

    /// Failing first, then running, then the rest; each opens its page.
    private var checkList: some View {
        let order: [CIStepState] = [.failure, .running, .queued, .cancelled, .success, .skipped]
        let sorted = pull.checks.steps.sorted { (order.firstIndex(of: $0.state) ?? 9) < (order.firstIndex(of: $1.state) ?? 9) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(pull.checks.checksSummary).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(sorted.enumerated()), id: \.offset) { _, step in
                        Button { if let url = pull.checkLinks[step.name] { NSWorkspace.shared.open(url) } } label: {
                            HStack(spacing: 7) {
                                CheckMark(state: step.state)
                                Text(step.name).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
                                if step.job != step.name {
                                    Text(step.job).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// A check's state as a small mark in the ring's colours.
private struct CheckMark: View {
    let state: CIStepState

    var body: some View {
        Group {
            switch state {
            case .success: Image(systemName: "checkmark.circle.fill")
            case .failure: Image(systemName: "xmark.circle.fill")
            case .running: Image(systemName: "circle.dotted.circle")
            case .queued: Image(systemName: "circle.dashed")
            case .skipped, .cancelled: Image(systemName: "minus.circle")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(state == .queued ? .white.opacity(0.4) : CIRingView.color(state))
        .symbolEffect(.pulse, options: .repeating, isActive: state == .running)
        .frame(width: 13)
    }
}

private struct ItemRow: View {
    let item: GitHubAnswer.Item
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            mark.frame(width: 16)
            Text("#\(item.number)").font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
            Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(item.state == .draft ? 0.6 : 0.92))
                .lineLimit(1)
            Spacer(minLength: 8)
            if item.comments > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "bubble.left").font(.system(size: 9))
                    Text("\(item.comments)")
                }
                .foregroundStyle(.white.opacity(0.4))
            }
            Text(item.repo.split(separator: "/").last.map(String.init) ?? item.repo).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            Text(GitHubResults.ago(item.updated)).foregroundStyle(.white.opacity(0.32)).lineLimit(1)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.1 : 0)))
        .contentShape(Rectangle())
        .help("\(item.repo)#\(item.number) · \(item.title)")
    }

    /// An eye for a review waiting on you; else the state's icon, in its checks' colour for an open PR.
    @ViewBuilder private var mark: some View {
        if item.wantsReview {
            Image(systemName: "eye.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
        } else {
            let color: Color = switch (item.state, item.checks) {
            case (.open, .failed): CIRingView.color(CIStepState.failure)
            case (.open, .pending): CIRingView.color(CIStepState.running)
            default: GitHubResults.color(item.state)
            }
            Image(systemName: GitHubResults.icon(item.state, pull: item.isPull))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
        }
    }
}

private struct RunRow: View {
    let run: GitHubAnswer.Run
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let ring = run.ring { CIRingView(ring: ring, diameter: 15) } else { CheckMark(state: run.state) }
            }
            .frame(width: 16)
            Text(run.workflow).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
            Text(run.title).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            Spacer(minLength: 8)
            Text(run.branch).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 120, alignment: .trailing)
            Text(run.repo.split(separator: "/").last.map(String.init) ?? run.repo).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(run.state.isDone ? GitHubResults.ago(run.started) : ciElapsed(context.date.timeIntervalSince(run.started)))
                    .foregroundStyle(run.state.isDone ? .white.opacity(0.32) : CIRingView.color(CIStepState.running))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.1 : 0)))
        .contentShape(Rectangle())
        .help("\(run.repo) · \(run.workflow) · \(run.event) on \(run.branch)")
    }
}
