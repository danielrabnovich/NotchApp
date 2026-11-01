import SwiftUI

struct TasksSettingsPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .tasks) {
            Section {
                if s.tasksEnabled {
                    ToggleRow("Open count beside the notch", isOn: $s.showTaskCount)
                    ToggleRow("Notes scratchpad", subtitle: "A free-form note next to your tasks, saved automatically.", isOn: $s.notesEnabled)
                }
            }
            Section {
                if RambleStore.canDictate {
                    ToggleRow("Dictate when Ramble opens",
                              subtitle: "Start talking straight away: it's turned into text on this Mac. Any dictation app can type into the box too.",
                              isOn: $s.rambleAutoDictate)
                } else {
                    LabeledContent("Dictation") {
                        Text("Any dictation app works: it types into the Ramble box")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Ramble")
            } footer: {
                FooterText("Type “ramble” in the bar or press \(HotKeys.combo(for: .ramble)?.display ?? "its shortcut"), talk or type everything on your mind, then Turn into Tasks: AI drafts tasks, events and a note, and you review them first.")
            }
            if s.tasksEnabled {
                Section {
                    ToggleRow("Morning brief", subtitle: "Drops down the first time you unlock your Mac each day.", isOn: $s.morningBrief)
                    if s.morningBrief {
                        Picker("Show after", selection: $s.briefHour) {
                            ForEach(Array(4...12), id: \.self) { h in Text(hourLabel(h)).tag(h) }
                        }
                    }
                    ToggleRow("Nudge before tasks are due", subtitle: "Type due dates naturally: “send deck by Friday 3pm”.", isOn: $s.dueNudges)
                    if s.dueNudges {
                        Picker("Nudge", selection: $s.nudgeLeadMinutes) {
                            Text("30 minutes before").tag(30)
                            Text("1 hour before").tag(60)
                            Text("2 hours before").tag(120)
                            Text("4 hours before").tag(240)
                            Text("1 day before").tag(1440)
                        }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    HStack {
                        Spacer()
                        Button("Show Brief Now") { BriefingService.shared.maybeShowBrief(force: true) }
                            .disabled(!s.morningBrief)
                    }
                }
            }
        }
    }
}

private func hourLabel(_ h: Int) -> String {
    let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
    return date.formatted(date: .omitted, time: .shortened)
}
