import AppKit
import SwiftUI

/// GitHub, Vercel and Linear: each on its own switch, signed in its own way, under one alerts choice.
struct DeveloperSettingsPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var github = GitHubService.shared
    @ObservedObject private var vercel = VercelService.shared
    @ObservedObject private var linear = LinearService.shared

    var body: some View {
        SettingsPage(pane: .developer) {
            Section {
                ToggleRow("GitHub", subtitle: "Reviews waiting on you, your pull requests, and the Actions ring after you push.", isOn: $s.githubEnabled)
                if s.githubEnabled {
                    StatusRow(title: githubTitle, detail: githubDetail, busy: github.connection == .connecting) { github.connect() }
                    TokenRow(account: "github", title: "Or use a token", placeholder: "ghp_…",
                             detail: "A classic token with the repo, notifications and workflow scopes (GitHub's notifications don't work with fine-grained tokens). Without one, NotchApp uses the gh command's login.",
                             link: URL(string: "https://github.com/settings/tokens/new?scopes=repo,notifications,workflow&description=NotchApp")!) { github.connect() }
                }
            } header: {
                Text("GitHub")
            }
            Section {
                ToggleRow("Vercel", subtitle: "Your deployments as they build, a ring per push, and a Prompt when a preview is ready or a build fails.", isOn: $s.vercelEnabled)
                if s.vercelEnabled {
                    StatusRow(title: vercelTitle, detail: vercelDetail, busy: vercel.connection == .connecting) { vercel.connect() }
                    TokenRow(account: "vercel", title: "Access token", placeholder: "Paste a Vercel token",
                             detail: "Create one in Vercel › Account Settings › Tokens, scoped to the teams you want to see. Redeploy, cancel and promote only happen when you pick them.",
                             link: URL(string: "https://vercel.com/account/settings/tokens")!) { vercel.connect() }
                }
            } header: {
                Text("Vercel")
            }
            Section {
                ToggleRow("Linear", subtitle: "The issue you're on beside the notch, your issues on Home and in Search, and assignments and mentions.", isOn: $s.linearEnabled)
                if s.linearEnabled {
                    StatusRow(title: linearTitle, detail: linearDetail, busy: linear.connection == .connecting) { linear.connect() }
                    TokenRow(account: "linear", title: "Personal API key", placeholder: "lin_api_…",
                             detail: "Create one in Linear › Settings › Security & access › Personal API keys. Start, Done and Assign to Me only happen when you pick them.",
                             link: URL(string: "https://linear.app/settings/account/security")!) { linear.connect() }
                }
            } header: {
                Text("Linear")
            }
            Section {
                Picker("Alerts", selection: $s.githubAlerts) {
                    ForEach(AppSettings.GitHubAlerts.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                FooterText("“Things that need me”: review requests and issues assigned to you (as Prompts), mentions and security alerts. “Everything” adds comments and other changes. What you push always says how its checks and deploys went, unless alerts are off.")
            }
            Section {
                RowLabel(title: "Following your pushes",
                         subtitle: "When you or an agent pushes from a repo an agent is working in, or a new commit lands on one of your pull requests, rings beside the notch follow it: Actions with a segment per job, Vercel with a segment per project. Each fills green, yellow and red as it passes, runs or fails.")
            } footer: {
                FooterText("In Search: “pr 12”, “my prs”, “reviews”, “ci”, “deploys”, “ENG-123”, “my issues”, “linear …”. ⌘K on a result lists everything you can do with it. Pin GitHub, Vercel or Linear in Glances, and add their cards to Home.")
            }
        }
    }

    private var githubTitle: String {
        switch github.connection {
        case .off: "Off"
        case .connecting: "Signing in…"
        case let .connected(login, _): "Signed in as \(login)"
        case .failed: "Not signed in"
        }
    }

    private var githubDetail: String {
        switch github.connection {
        case .off: ""
        case .connecting: "Asking GitHub who you are."
        case let .connected(_, via): "Through \(via). Read-only, apart from the actions you pick (re-run, cancel) and marking notifications read when you open them from the notch."
        case let .failed(message): GitHubService.hasGH ? message : "\(message) The GitHub command isn't installed: “brew install gh”, then “gh auth login”."
        }
    }

    private var vercelTitle: String {
        switch vercel.connection {
        case .off: "Off"
        case .connecting: "Signing in…"
        case let .connected(user): "Signed in as \(user)"
        case .failed: "Not signed in"
        }
    }

    private var vercelDetail: String {
        if case let .failed(m) = vercel.connection { return m }
        return vercel.connection.user != nil ? "Checks every minute, every few seconds while something builds or just after you push." : ""
    }

    private var linearTitle: String {
        switch linear.connection {
        case .off: "Off"
        case .connecting: "Signing in…"
        case let .connected(user): "Signed in as \(user)"
        case .failed: "Not signed in"
        }
    }

    private var linearDetail: String {
        if case let .failed(m) = linear.connection { return m }
        return linear.connection.user != nil ? "\(linear.mine.count) open issue\(linear.mine.count == 1 ? "" : "s") assigned to you, \(linear.inProgress.count) in progress." : ""
    }
}

/// Who it's signed in as, with a way to check again.
private struct StatusRow: View {
    let title: String
    let detail: String
    let busy: Bool
    let retry: () -> Void

    var body: some View {
        LabeledContent {
            if busy { ProgressView().controlSize(.small) } else { Button("Check Again", action: retry) }
        } label: {
            RowLabel(title: title, subtitle: detail.isEmpty ? nil : detail)
        }
    }
}

/// A token or key, saved to the Keychain (never shown again), or removed.
private struct TokenRow: View {
    let account: String
    let title: String
    let placeholder: String
    let detail: String
    let link: URL
    let changed: () -> Void
    @State private var text = ""
    @State private var saved = false

    var body: some View {
        LabeledContent {
            if saved {
                Button("Remove") {
                    DevKeys.set(nil, for: account)
                    saved = false
                    changed()
                }
            } else {
                HStack {
                    SecureField(title, text: $text, prompt: Text(placeholder))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button("Save") {
                        DevKeys.set(text, for: account)
                        text = ""
                        saved = DevKeys.get(account) != nil
                        changed()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                RowLabel(title: saved ? "\(title) saved" : title, subtitle: saved ? "Kept in your Mac's Keychain." : detail)
                if !saved { Link("Create one", destination: link).font(.caption) }
            }
        }
        .onAppear { saved = DevKeys.get(account) != nil }
    }
}
