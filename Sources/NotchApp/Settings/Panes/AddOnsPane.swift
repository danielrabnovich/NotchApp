import SwiftUI

struct AddOnsPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .addOns) {
            Section("Tabs") {
                ToggleRow("Music", subtitle: "Now playing with controls on a Home tab, plus a live activity beside the notch.",
                          isOn: Binding(get: { s.musicEnabled }, set: { s.musicEnabled = $0; s.musicLiveActivity = $0 }))
                ToggleRow("Calendar", subtitle: "Today's events on the Home tab, with meeting alerts. Search can use your calendar either way.",
                          isOn: $s.calendarEnabled)
                ToggleRow("Timer", subtitle: "Countdowns, Pomodoro and a stopwatch. “timer 10m” in Search works either way.", isOn: $s.timerEnabled)
                ToggleRow("Mixer", subtitle: "Per-app volume.", isOn: $s.mixerEnabled)
                ToggleRow("Controls", subtitle: "Quick actions you pick: toggles, a port viewer, speed test, copy text from the screen…",
                          isOn: $s.controlsEnabled)
                ToggleRow("Stats", subtitle: "CPU, GPU, memory, temperatures and power.", isOn: $s.statsEnabled)
                ToggleRow("Tools", subtitle: "Network and speed test, a cleaner, an app uninstaller and Bluetooth batteries.",
                          isOn: $s.toolsEnabled)
                ToggleRow("Agents", subtitle: "Claude Code, Codex, OpenCode and ZCode sessions at a glance, with today's token usage.",
                          isOn: $s.agentsEnabled)
            }
            Section("Extras") {
                ToggleRow("Camera mirror", subtitle: "A quick look at yourself from the notch.", isOn: $s.cameraMirrorEnabled)
                ToggleRow("Volume & brightness", subtitle: "Shows them in the notch instead of the system overlay.",
                          isOn: Binding(get: { s.volumeHUD || s.brightnessHUD }, set: { s.volumeHUD = $0; s.brightnessHUD = $0 }))
                ToggleRow("Charging animation", subtitle: "When you plug in.", isOn: $s.chargingAnimation)
                ToggleRow("Morning brief", subtitle: "Your day at a glance on the first unlock of the morning.", isOn: $s.morningBrief)
                ToggleRow("GitHub", subtitle: "Reviews waiting on you, your pull requests, and the Actions ring after you push.",
                          isOn: $s.githubEnabled)
                ToggleRow("Vercel", subtitle: "Deployments as they build, and a Prompt when a preview is ready or a build fails.",
                          isOn: $s.vercelEnabled)
                ToggleRow("Linear", subtitle: "The issue you're on beside the notch, your issues on Home, and assignments and mentions.",
                          isOn: $s.linearEnabled)
                ToggleRow("Clipboard history", subtitle: "Recent copies on the Shelf, and “clip …” in Search. Password managers are skipped.",
                          isOn: $s.clipboardHistory)
            }
        }
    }
}
