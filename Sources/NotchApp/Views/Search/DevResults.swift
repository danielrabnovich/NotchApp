import NotchKit
import SwiftUI

/// What the developer results (GitHub, Vercel, Linear) have for the keyboard: their rows' links.
@MainActor
enum DevResultsInfo {
    static func links(_ job: AssistantStore.Job) -> [URL]? {
        switch job.route {
        case .github?: job.github?.links
        case .deploys?: job.deploys?.links
        case .linear?: job.linear?.links
        default: nil
        }
    }
}

// MARK: - Vercel

/// Recent deployments: each project's ring (Queued → Building → Ready) or state, its branch and
/// commit, production or preview, and when.
struct DeploysResults: View {
    let answer: DeploysAnswer
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DevHeader(title: answer.headline, detail: answer.detail)
            if answer.deployments.isEmpty {
                DevEmpty(text: "No deployments")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(Array(answer.deployments.enumerated()), id: \.element.id) { i, d in
                                DeployRow(d: d, selected: i == selection).id(i)
                                    .onTapGesture { if let u = d.url ?? d.inspector { NSWorkspace.shared.open(u) } }
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

struct DeployRow: View {
    let d: VercelService.Deployment
    var selected = false

    var body: some View {
        HStack(spacing: 9) {
            DeployMark(d: d).frame(width: 16)
            Text(d.project).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
            Text(d.production ? "Production" : "Preview")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(d.production ? Color(red: 0.4, green: 0.75, blue: 1) : .white.opacity(0.55))
                .padding(.horizontal, 5).frame(height: 15)
                .background(Capsule().fill((d.production ? Color(red: 0.4, green: 0.75, blue: 1) : .white).opacity(0.13)))
            Text(d.message ?? "").foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            Spacer(minLength: 8)
            if let branch = d.branch {
                Text(branch).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 130, alignment: .trailing)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(d.isDone ? GitHubResults.ago(d.created) : ciElapsed(context.date.timeIntervalSince(d.created)))
                    .foregroundStyle(d.isDone ? .white.opacity(0.32) : CIRingView.color(CIStepState.running))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.1 : 0)))
        .contentShape(Rectangle())
        .help([d.project, d.label, d.url?.host(), d.creator].compactMap { $0 }.joined(separator: " · "))
    }
}

/// A deployment's state: its little ring while it builds, else a mark in the ring's colours.
struct DeployMark: View {
    let d: VercelService.Deployment
    var size: CGFloat = 15

    var body: some View {
        if d.isDone {
            Image(systemName: d.state == .ready ? "checkmark.circle.fill" : d.state == .error ? "xmark.circle.fill" : "minus.circle")
                .font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(d.state == .ready ? CIRingView.color(CIStepState.success) : d.state == .error ? CIRingView.color(CIStepState.failure) : .white.opacity(0.45))
        } else {
            CIRingView(ring: CIRing(steps: d.steps), diameter: size, style: .steps)
        }
    }
}

// MARK: - Linear

/// One Linear issue in full, or a list of them.
struct LinearResults: View {
    let answer: LinearAnswer
    @Binding var selection: Int
    var narrow = false

    var body: some View {
        if let issue = answer.issue {
            IssueCard(issue: issue, narrow: narrow)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                DevHeader(title: answer.headline, detail: answer.detail)
                if answer.issues.isEmpty {
                    DevEmpty(text: "No issues")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 2) {
                                ForEach(Array(answer.issues.enumerated()), id: \.element.id) { i, issue in
                                    IssueRow(issue: issue, selected: i == selection).id(i)
                                        .onTapGesture { NSWorkspace.shared.open(issue.url) }
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
}

/// Linear's status circle: empty for todo, half for in progress, a check when done, in the
/// workflow state's own colour.
struct LinearStatusIcon: View {
    let state: LinearService.Issue.WorkflowState
    var size: CGFloat = 12

    var body: some View {
        let color = Color(hex: state.color)
        ZStack {
            switch state.type {
            case "completed":
                Image(systemName: "checkmark.circle.fill").font(.system(size: size)).foregroundStyle(color)
            case "canceled":
                Image(systemName: "xmark.circle.fill").font(.system(size: size)).foregroundStyle(color)
            case "started":
                Circle().stroke(color, lineWidth: size / 7)
                Circle().trim(from: 0, to: 0.5).fill(color).rotationEffect(.degrees(-90)).padding(size / 4.5)
            case "backlog", "triage":
                Circle().stroke(color, style: StrokeStyle(lineWidth: size / 7, dash: [size / 6, size / 8]))
            default:
                Circle().stroke(color, lineWidth: size / 7)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Linear's priority bars (urgent is an exclamation mark).
struct LinearPriorityIcon: View {
    let priority: Int

    var body: some View {
        switch priority {
        case 1:
            Image(systemName: "exclamationmark.square.fill").font(.system(size: 11)).foregroundStyle(.orange)
        case 2, 3, 4:
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(.white.opacity(i < 5 - priority ? 0.8 : 0.22))
                        .frame(width: 2.5, height: CGFloat(4 + i * 3))
                }
            }
            .frame(width: 12, height: 11)
        default:
            Text("···").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.35)).frame(width: 12)
        }
    }
}

private struct IssueRow: View {
    let issue: LinearService.Issue
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            LinearPriorityIcon(priority: issue.priority)
            Text(issue.identifier).font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                .frame(minWidth: 52, alignment: .leading)
            LinearStatusIcon(state: issue.state)
            Text(issue.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
            Spacer(minLength: 8)
            ForEach(issue.labels.prefix(2), id: \.self) { label in
                Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    .padding(.horizontal, 5).frame(height: 15)
                    .background(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            }
            if let assignee = issue.assignee, issue.assigneeID != LinearService.shared.userID {
                Text(assignee).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Text(GitHubResults.ago(issue.updated)).foregroundStyle(.white.opacity(0.32)).lineLimit(1)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.1 : 0)))
        .contentShape(Rectangle())
        .help("\(issue.identifier) · \(issue.state.name) · \(issue.title)")
    }
}

/// One issue: its status, priority and where it sits (project, cycle, labels), the start of its
/// description, linked pull requests, and Start / Done / Copy Branch.
private struct IssueCard: View {
    let issue: LinearService.Issue
    let narrow: Bool
    @State private var copied: String?

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    LinearPriorityIcon(priority: issue.priority)
                    Text(issue.identifier).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
                    if let project = issue.project { Text("· \(project)").foregroundStyle(.white.opacity(0.4)).lineLimit(1) }
                    if let cycle = issue.cycle { Text("· \(cycle)").foregroundStyle(.white.opacity(0.4)).lineLimit(1) }
                }
                .font(.system(size: 11.5, weight: .medium))
                Text(issue.title).font(.system(size: 16, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        LinearStatusIcon(state: issue.state, size: 11)
                        Text(issue.state.name).font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: issue.state.color))
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Capsule().fill(Color(hex: issue.state.color).opacity(0.16)))
                    Text(issue.assignee ?? "Unassigned")
                    if !issue.priorityLabel.isEmpty, issue.priority > 0 { Text("· \(issue.priorityLabel)") }
                    if let e = issue.estimate { Text("· \(formatSmall(e)) pt") }
                    if let due = issue.due { Text("· due \(due)") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                if !issue.labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(issue.labels, id: \.self) { label in
                            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                                .padding(.horizontal, 6).frame(height: 16)
                                .background(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                        }
                    }
                }
                Spacer(minLength: 4)
                buttons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !narrow, issue.description != nil || !issue.links.isEmpty {
                side.frame(width: 230)
            }
        }
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = issue.description {
                Text(text.replacingOccurrences(of: "\n\n", with: "\n"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(issue.links.isEmpty ? 7 : 4)
            }
            if !issue.links.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(issue.links.prefix(3).enumerated()), id: \.offset) { _, link in
                        Button { NSWorkspace.shared.open(link.url) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: link.url.host()?.contains("github") == true ? "arrow.triangle.pull" : "link")
                                    .font(.system(size: 10, weight: .semibold)).frame(width: 13)
                                Text(link.title).lineLimit(1)
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.75))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var buttons: some View {
        let linear = LinearService.shared
        return HStack(spacing: 6) {
            Button("Open") { linear.open(issue) }.buttonStyle(NotchPillButtonStyle(primary: true))
            if issue.state.type != "started", !issue.done {
                Button("Start") { linear.move(issue, to: "started") }.buttonStyle(NotchPillButtonStyle())
            }
            if !issue.done {
                Button("Done") { linear.move(issue, to: "completed") }.buttonStyle(NotchPillButtonStyle())
            }
            if let branch = issue.branch {
                Button(copied == "branch" ? "Copied" : "Copy Branch") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(branch, forType: .string)
                    copied = "branch"
                }
                .buttonStyle(NotchPillButtonStyle())
                .help(branch)
            }
            if issue.assigneeID != linear.userID {
                Button("Assign to Me") { linear.assignToMe(issue) }.buttonStyle(NotchPillButtonStyle())
            }
        }
    }
}

// MARK: - Shared

struct DevHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45)) }
            Spacer(minLength: 0)
        }
    }
}

struct DevEmpty: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(.white.opacity(0.4))
            Text(text).foregroundStyle(.white.opacity(0.5))
        }
        .font(.system(size: 12.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
