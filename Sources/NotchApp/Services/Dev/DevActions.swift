import AppKit
import NotchKit

/// ⌘K on a GitHub, Vercel or Linear result: everything that can be done to the highlighted row
/// (or the one card), each with its shortcut.
@MainActor
enum DevActions {
    static func forJob(_ job: AssistantStore.Job, index: Int) -> (target: ActionPanel.Target, actions: [ItemAction])? {
        guard job.state == .done else { return nil }
        switch job.route {
        case .github?:
            guard let a = job.github else { return nil }
            if let pull = a.pull { return (.init(title: "\(pull.repo)#\(pull.number)", icon: nil), forPull(pull)) }
            if a.items.indices.contains(index) {
                let item = a.items[index]
                return (.init(title: "\(item.repo.split(separator: "/").last ?? "")#\(item.number)", icon: nil), forItem(item, choices: a.choices))
            }
            if a.runs.indices.contains(index) {
                let run = a.runs[index]
                return (.init(title: run.workflow, icon: nil), forRun(run))
            }
        case .deploys?:
            guard let a = job.deploys, a.deployments.indices.contains(index) else { return nil }
            let d = a.deployments[index]
            return (.init(title: d.project, icon: nil), forDeployment(d))
        case .linear?:
            guard let a = job.linear else { return nil }
            if let issue = a.issue ?? (a.issues.indices.contains(index) ? a.issues[index] : nil) {
                return (.init(title: issue.identifier, icon: nil), forIssue(issue))
            }
        default:
            break
        }
        return nil
    }

    // MARK: - GitHub

    static func forPull(_ pull: GitHubAnswer.Pull) -> [ItemAction] {
        var out = [open(pull.url, "Open on GitHub"),
                   ItemAction(id: "files", title: "Open Changed Files", icon: "doc.text.magnifyingglass", key: .command("f", .shift)) {
                       NSWorkspace.shared.open(pull.url.appendingPathComponent("files"))
                   },
                   ItemAction(id: "checks", title: "Open Checks", icon: "checklist", key: .command("o", .shift)) {
                       NSWorkspace.shared.open(pull.url.appendingPathComponent("checks"))
                   }]
        out += copies(link: pull.url, title: "\(pull.repo)#\(pull.number) \(pull.title)", group: 1)
        if pull.state == .open || pull.state == .draft {
            out.append(copy("checkout", "Copy Checkout Command", "gh pr checkout \(pull.number) -R \(pull.repo)", what: "checkout command",
                            key: .command("k", .shift), group: 1))
        }
        out.append(copy("branch", "Copy Branch Name", pull.head, what: "branch name", key: .command("b", .shift), group: 1))
        if pull.checks.hasFailure, !pull.runIDs.isEmpty, pull.checks.outcome != .running {
            out.append(ItemAction(id: "rerun", title: "Re-run Failed Jobs", icon: "arrow.clockwise", key: .command("r", .shift), group: 2) {
                Task { notice(await GitHubSearch.rerunFailed(pull) ? "Re-running failed jobs" : "Couldn't re-run", pull.title) }
            })
        }
        return out
    }

    static func forItem(_ item: GitHubAnswer.Item, choices: Bool) -> [ItemAction] {
        var out: [ItemAction] = []
        if item.isPull {
            // Already a list of choices: ↩ shows it here; otherwise this is the way to.
            let show = ItemAction(id: "show", title: "Show Here", icon: "rectangle.and.text.magnifyingglass", key: choices ? .return : .command("i")) {
                AssistantStore.shared.run("\(item.repo)#\(item.number)", route: .github)
            }
            out = choices ? [show, open(item.url, "Open on GitHub", key: .command("o"))] : [open(item.url, "Open on GitHub"), show]
        } else {
            out = [open(item.url, "Open on GitHub")]
        }
        out += copies(link: item.url, title: "\(item.repo)#\(item.number) \(item.title)", group: 1)
        out.append(copy("ref", "Copy Reference", "\(item.repo)#\(item.number)", what: "reference", key: .command("r", .shift), group: 1))
        if item.isPull, item.state == .open || item.state == .draft {
            out.append(copy("checkout", "Copy Checkout Command", "gh pr checkout \(item.number) -R \(item.repo)", what: "checkout command",
                            key: .command("k", .shift), group: 1))
        }
        return out
    }

    static func forRun(_ run: GitHubAnswer.Run) -> [ItemAction] {
        var out = [open(run.url, "Open Run")]
        out += copies(link: run.url, title: "\(run.workflow) · \(run.branch)", group: 1)
        if run.state.isDone {
            if run.state == .failure {
                out.append(ItemAction(id: "rerunfailed", title: "Re-run Failed Jobs", icon: "arrow.clockwise", key: .command("r", .shift), group: 2) {
                    runAction(run, "rerun-failed-jobs", done: "Re-running failed jobs")
                })
            }
            out.append(ItemAction(id: "rerun", title: "Re-run All Jobs", icon: "arrow.clockwise.circle", group: 2) {
                runAction(run, "rerun", done: "Re-running \(run.workflow)")
            })
        } else {
            out.append(ItemAction(id: "cancel", title: "Cancel Run", icon: "stop.circle", destructive: true, group: 2) {
                runAction(run, "cancel", done: "Cancelling \(run.workflow)")
            })
        }
        return out
    }

    private static func runAction(_ run: GitHubAnswer.Run, _ verb: String, done: String) {
        Task {
            let r = try? await GitHubService.shared.request("/repos/\(run.repo)/actions/runs/\(run.id)/\(verb)", method: "POST")
            let ok = r.map { (200..<300).contains($0.1.statusCode) } ?? false
            notice(ok ? done : "GitHub said no", "\(run.workflow) · \(run.branch)", ok: ok)
        }
    }

    // MARK: - Vercel

    static func forDeployment(_ d: VercelService.Deployment) -> [ItemAction] {
        let vercel = VercelService.shared
        var out: [ItemAction] = []
        if let url = d.url, d.state == .ready { out.append(open(url, d.production ? "Open Site" : "Open Preview")) }
        if let inspector = d.inspector {
            out.append(ItemAction(id: "inspect", title: d.state == .error ? "Open Build Logs" : "Open in Vercel", icon: "doc.text.magnifyingglass",
                                  key: out.isEmpty ? .return : .command("o")) { NSWorkspace.shared.open(inspector) })
        }
        if let url = d.url { out.append(copy("copyurl", "Copy URL", url.absoluteString, what: "URL", key: .command("c", .shift), group: 1)) }
        if let branch = d.branch { out.append(copy("branch", "Copy Branch Name", branch, what: "branch name", key: .command("b", .shift), group: 1)) }
        if d.isDone {
            out.append(ItemAction(id: "redeploy", title: "Redeploy", icon: "arrow.clockwise", key: .command("r", .shift), group: 2) { vercel.redeploy(d) })
        } else {
            out.append(ItemAction(id: "cancel", title: "Cancel Deployment", icon: "stop.circle", destructive: true, group: 2) { vercel.cancel(d) })
        }
        if d.state == .ready, d.projectID != nil {
            out.append(ItemAction(id: "promote", title: d.production ? "Make This Production Again" : "Promote to Production",
                                  icon: "arrow.up.circle", destructive: true, group: 2) { vercel.promote(d) })
        }
        return out
    }

    // MARK: - Linear

    static func forIssue(_ issue: LinearService.Issue) -> [ItemAction] {
        let linear = LinearService.shared
        var out = [open(issue.url, "Open in Linear")]
        out.append(copy("id", "Copy ID", issue.identifier, what: "ID", key: .command("i", .shift), group: 1))
        out += copies(link: issue.url, title: "\(issue.identifier) \(issue.title)", group: 1)
        if let branch = issue.branch {
            out.append(copy("branch", "Copy Branch Name", branch, what: "branch name", key: .command("b", .shift), group: 1))
        }
        if issue.state.type != "started", !issue.done {
            out.append(ItemAction(id: "start", title: "Start", icon: "circle.lefthalf.filled", key: .command("s", .shift), group: 2) {
                linear.move(issue, to: "started")
            })
        }
        if !issue.done {
            out.append(ItemAction(id: "done", title: "Mark Done", icon: "checkmark.circle", key: .command("d", .shift), group: 2) {
                linear.move(issue, to: "completed")
            })
        }
        if issue.state.type == "started" || issue.done {
            out.append(ItemAction(id: "todo", title: "Back to Todo", icon: "circle", group: 2) { linear.move(issue, to: "unstarted") })
        }
        if issue.assigneeID != linear.userID {
            out.append(ItemAction(id: "assign", title: "Assign to Me", icon: "person.crop.circle.badge.checkmark", key: .command("a", .shift), group: 2) {
                linear.assignToMe(issue)
            })
        }
        return out
    }

    // MARK: - Shared

    private static func open(_ url: URL, _ title: String, key: ActionKey = .return) -> ItemAction {
        ItemAction(id: "open-\(title)", title: title, icon: "arrow.up.forward.app", key: key) { NSWorkspace.shared.open(url) }
    }

    private static func copies(link: URL, title: String, group: Int) -> [ItemAction] {
        [copy("link", "Copy Link", link.absoluteString, what: "link", key: .command("c", .shift), group: group),
         ItemAction(id: "md", title: "Copy as Markdown Link", icon: "text.badge.plus", group: group) {
             let text = "[\(title.replacingOccurrences(of: "]", with: ")"))](\(link.absoluteString))"
             NSPasteboard.general.clearContents()
             NSPasteboard.general.setString(text, forType: .string)
             notice("Copied Markdown link", text)
         }]
    }

    private static func copy(_ id: String, _ title: String, _ text: String, what: String, key: ActionKey? = nil, group: Int) -> ItemAction {
        ItemAction(id: id, title: title, icon: "doc.on.doc", key: key, group: group) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            notice("Copied \(what)", text)
        }
    }

    private static func notice(_ title: String, _ detail: String, ok: Bool = true) {
        ActivityCenter.shared.show(.notice(title: title, detail: detail, icon: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                           tone: ok ? .info : .warning), for: 2.5)
    }
}
