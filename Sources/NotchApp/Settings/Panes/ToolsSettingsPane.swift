import AVFoundation
import SwiftUI

struct ToolsSettingsPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var speed = SpeedTest.shared

    var body: some View {
        SettingsPage(pane: .tools) {
            Section {
            }
            Section("Network") {
                ToggleRow("Connection alerts", subtitle: "When you go offline or come back, a VPN connects or drops, or your public IP changes.",
                          isOn: $s.connectionAlerts)
                ToggleRow("Dev server alerts", subtitle: "When a local server starts (npm run dev, rails s…), with a button to open it.",
                          isOn: $s.devServerAlerts)
                ToggleRow("Show speed tests beside the notch", subtitle: "The live speed while a test runs.", isOn: $s.speedTestLiveActivity)
                LabeledContent {
                    Button("Clear History") { speed.clearHistory() }.disabled(speed.history.isEmpty)
                } label: {
                    RowLabel(title: "Speed test history", subtitle: speed.history.isEmpty ? "No tests yet."
                             : "\(speed.history.count) result\(speed.history.count == 1 ? "" : "s"). Last: ↓ \(formatMbps(speed.history[0].download)) ↑ \(formatMbps(speed.history[0].upload)) Mbps.")
                }
            }
            Section {
                ToggleRow("Low disk space alert", subtitle: "A heads-up once a day when less than 10 GB is free.", isOn: $s.lowDiskAlerts)
            } header: {
                Text("Cleaner")
            } footer: {
                FooterText("Everything the cleaner removes goes to the Trash, so you can put it back. To include the Trash's own size, give NotchApp Full Disk Access in Privacy & Security.")
            }
            Section("Devices") {
                ToggleRow("Low battery alerts", subtitle: "When AirPods, a mouse or a keyboard drops to 20%.", isOn: $s.deviceBatteryAlerts)
                ToggleRow("Microphone and camera alerts", subtitle: "A heads-up when an app starts using them, and which app has the microphone.",
                          isOn: $s.privacyAlerts)
                ToggleRow("Sound alerts", subtitle: "While you've got headphones on: a doorbell, a knock, a smoke alarm, a baby, a dog, a siren or a phone. Heard on this Mac, nothing kept; the mic's orange dot shows while it listens.",
                          isOn: $s.soundAlerts)
                    .onChange(of: s.soundAlerts) { _, on in
                        guard on else { return }
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            DispatchQueue.main.async { SoundAlerts.shared.reconcile(); Permissions.shared.refresh() }
                        }
                    }
            }
        }
    }
}
