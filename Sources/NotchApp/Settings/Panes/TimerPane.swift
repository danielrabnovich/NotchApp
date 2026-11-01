import SwiftUI

struct TimerPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .timer) {
            Section {
                if s.timerEnabled {
                    ToggleRow("Countdown beside the notch", subtitle: "A progress ring and the time left while the notch is closed.",
                              isOn: $s.timerLiveActivity)
                    ToggleRow("Play sounds", subtitle: "A chime when a timer or Pomodoro phase ends.", isOn: $s.timerSounds)
                }
            }
            if s.timerEnabled {
                Section("Pomodoro") {
                    ToggleRow("Start the next phase automatically", subtitle: "Go straight from focus to break and back.",
                              isOn: $s.pomodoroAutoStart)
                }
            }
        }
    }
}
