import SwiftUI

struct UpdatesPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        SettingsPage(pane: .updates) {
            Section {
                ToggleRow("Check for updates", subtitle: "Every six hours. Review and install them from the Controls tab.", isOn: $s.updateChecks)
                if s.updateChecks {
                    ToggleRow("Include apps that update themselves", subtitle: "Apps using Sparkle, like IINA, Rectangle and HandBrake.",
                              isOn: $s.updateChecksApps)
                    ToggleRow("Alert when new updates appear", isOn: $s.updateAlerts)
                }
            }
            if s.updateChecks {
                Section {
                    LabeledContent {
                        HStack(spacing: 10) {
                            if updates.checking { ProgressView().controlSize(.small) }
                            Button("Check Now") { updates.check() }.disabled(updates.checking)
                        }
                    } label: {
                        RowLabel(title: updates.updates.isEmpty ? "No updates found" : "\(updates.updates.count) available",
                                 subtitle: updates.lastChecked.map { "Last checked " + $0.formatted(.relative(presentation: .named)) })
                    }
                    if UpdateChecker.brew == nil {
                        Text("Homebrew isn't installed, so only self-updating apps are checked.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
