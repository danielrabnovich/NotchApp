import AppKit
import Combine
import SwiftUI

struct HUDPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var mixer = AudioMixer.shared
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPage(pane: .hud) {
            Section {
                HStack(spacing: 14) {
                    NotchPreviewCard(title: "Volume", subtitle: "In place of the macOS pop-up", isOn: s.volumeHUD,
                                     notchWidth: 190, action: { s.volumeHUD.toggle() }) {
                        PreviewFlash(icon: "speaker.wave.2.fill", level: 0.62, tint: .white)
                    }
                    NotchPreviewCard(title: "Brightness", subtitle: "In place of the macOS pop-up", isOn: s.brightnessHUD,
                                     notchWidth: 190, action: { s.brightnessHUD.toggle() }) {
                        PreviewFlash(icon: "sun.max.fill", level: 0.4, tint: .yellow)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Show in the notch")
            } footer: {
                FooterText("Hold Shift + Option while pressing a volume or brightness key for finer steps.")
            }
            Section {
                ToggleRow("Sound tab", subtitle: "System volume, output device and a fader for each app.", isOn: $s.mixerEnabled)
                if s.mixerEnabled {
                    PermissionRow(title: "System audio recording",
                                  subtitle: "Needed to change an app's volume. Apps left at 100% are never touched.",
                                  state: mixer.permission == .granted ? .granted : mixer.permission == .denied ? .denied : .unknown,
                                  request: { mixer.requestPermission() },
                                  openSettings: { AudioCapturePermission.openSettings() })
                }
            } header: {
                Text("Sound mixer")
            }
            Section("Permission") {
                PermissionRow(title: "Accessibility",
                              subtitle: trusted ? nil : "Without it the notch HUD still appears, but macOS shows its own overlay too.",
                              state: trusted ? .granted : .unknown) {
                    HUDController.shared.requestAccessibility()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }
}

/// A Flash as the preview shows it: a glyph and a level bar.
private struct PreviewFlash: View {
    let icon: String
    let level: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 8.5, weight: .semibold))
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.2))
                    .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: g.size.width * level) }
            }
            .frame(height: 3.5)
            Text("\(Int(level * 100))%").font(.system(size: 8, weight: .semibold).monospacedDigit())
        }
    }
}
