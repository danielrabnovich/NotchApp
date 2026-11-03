import AppKit
import SwiftUI

/// Developer services: GitHub for now. Signs in with the gh command's login, or a pasted token.
struct DeveloperSettingsPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var github = GitHubService.shared
    @State private var token = ""
    @State private var hasToken = DevKeys.get("github") != nil

    var body: some View {
        SettingsPage(pane: .developer) {
            Section {
                LabeledContent {
                    switch github.connection {
                    case .connected, .failed:
                        Button("Check Again") { github.connect() }
                    case .connecting:
                        ProgressView().controlSize(.small)
                    case .off:
                        EmptyView()
                    }
                } label: {
                    RowLabel(title: statusTitle, subtitle: statusDetail)
                }
                if hasToken {
                    LabeledContent {
                        Button("Remove Token") {
                            DevKeys.set(nil, for: "github")
                            hasToken = false
                            github.connect()
                        }
                    } label: {
                        RowLabel(title: "Personal access token", subtitle: "Kept in your Mac's Keychain. Without it, NotchApp uses the gh command's login.")
                    }
                } else {
                    LabeledContent {
                        HStack {
                            SecureField("Token", text: $token, prompt: Text("ghp_…"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            Button("Save") {
                                DevKeys.set(token, for: "github")
                                token = ""
                                hasToken = DevKeys.get("github") != nil
                                github.connect()
                            }
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } label: {
                        RowLabel(title: "Or use a token",
                                 subtitle: "A classic token with the repo, notifications and workflow scopes (GitHub's notifications don't work with fine-grained tokens). Kept in your Mac's Keychain.")
                    }
                }
            } header: {
                Text("GitHub")
            }
            Section {
                Picker("Alerts", selection: $s.githubAlerts) {
                    ForEach(AppSettings.GitHubAlerts.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                FooterText("“Things that need me” is review requests (with Open), mentions, assignments and security alerts. “Everything” adds comments and changes on what you follow. Your own pushes always say how their checks went.")
            }
            Section {
                RowLabel(title: "Following your pushes",
                         subtitle: "When you or an agent pushes from a repo an agent is working in, or a new commit lands on one of your pull requests, the GitHub Glance shows a ring that fills green, yellow and red as the Actions steps pass, run or fail. A failure offers Open Logs and Re-run Failed.")
            } footer: {
                FooterText("Pin “GitHub” in Glances to keep it beside the notch; it joins by itself while a run is followed. Add the GitHub card to Home for your pull requests.")
            }
        }
    }

    private var statusTitle: String {
        switch github.connection {
        case .off: "Off"
        case .connecting: "Signing in…"
        case let .connected(login, _): "Signed in as \(login)"
        case .failed: "Not signed in"
        }
    }

    private var statusDetail: String {
        switch github.connection {
        case .off: "Turn GitHub on above."
        case .connecting: "Asking GitHub who you are."
        case let .connected(_, via): "Through \(via). Read-only, apart from re-running failed jobs and marking notifications read when you open them from the notch."
        case let .failed(message):
            GitHubService.hasGH ? message : "\(message) The GitHub command isn't installed: “brew install gh”, then “gh auth login”."
        }
    }
}
