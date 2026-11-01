import SwiftUI

struct GeneralPane: View {
    @EnvironmentObject private var s: AppSettings
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        SettingsPage(pane: .general) {
            Section("Opening") {
                ToggleRow("Ready to type when it opens", subtitle: "The cursor is already in the search bar when the notch opens on hover.",
                          isOn: $s.focusSearchOnHover)
                Picker(selection: $s.openMode) {
                    ForEach(AppSettings.OpenMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    RowLabel(title: "Open the notch on", subtitle: s.openMode == .hover ? "Rest the pointer on the notch to open it." : "Click the notch to open it.")
                }
                .pickerStyle(.segmented)
                Picker(selection: $s.openTo) {
                    ForEach(NotchTab.allCases) { Text($0.title).tag($0.rawValue) }
                    Divider()
                    Text("Where I left it").tag("last")
                } label: {
                    RowLabel(title: "Open on", subtitle: "The screen the notch shows when it opens. Shortcuts and drops still go where they point.")
                }
                if s.openMode == .hover {
                    LabeledContent {
                        HStack {
                            Slider(value: $s.hoverDelay, in: 0...1, step: 0.05)
                                .frame(maxWidth: 220)
                            Text(String(format: "%.2fs", s.hoverDelay))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    } label: {
                        RowLabel(title: "Hover delay", subtitle: "Longer means fewer accidental opens.")
                    }
                }
            }
            Section("Displays") {
                Picker("Show the notch on", selection: $s.displayMode) {
                    ForEach(AppSettings.DisplayMode.allCases) { Text($0.label).tag($0) }
                }
                ToggleRow("Fake notch on other displays", subtitle: "Draw a notch on screens that don't have one.", isOn: $s.showFakeNotch)
            }
            Section("System") {
                ToggleRow("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        LaunchAtLogin.isEnabled = v
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ToggleRow("Menu bar icon",
                          subtitle: s.showMenuBarIcon ? nil : "To get back here, right-click the notch or open NotchApp again from Finder.",
                          isOn: $s.showMenuBarIcon)
            }
        }
    }
}
