import SwiftUI

struct AppearancePane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .appearance) {
            Section("Color") {
                Picker(selection: $s.accentMode) {
                    ForEach(AppSettings.AccentMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    RowLabel(title: "Accent color", subtitle: "Used for the visualizer, HUD bars and highlights.")
                }
                if s.accentMode == .custom {
                    ColorPicker("Custom color", selection: Binding(get: { s.customAccent }, set: { s.customAccent = $0 }),
                                supportsOpacity: false)
                }
            }
            if AppSettings.NotchMaterial.isAvailable {
                Section {
                    HStack(spacing: 14) {
                        ForEach(AppSettings.NotchMaterial.allCases) { material in
                            NotchPreviewCard(title: material.label,
                                             subtitle: material == .black ? "Solid, like the notch itself" : "Melts into clear glass",
                                             isOn: s.notchMaterial == material, notchHeight: 58, notchWidth: 200,
                                             glass: material == .glass, action: { s.notchMaterial = material }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Capsule().fill(.white.opacity(0.85)).frame(width: 60, height: 4)
                                    Capsule().fill(.white.opacity(0.45)).frame(width: 100, height: 4)
                                    Capsule().fill(.white.opacity(0.45)).frame(width: 80, height: 4)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 16)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if s.notchMaterial == .glass {
                        Picker(selection: $s.glassLevel) {
                            ForEach(AppSettings.GlassLevel.allCases) { Text($0.label).tag($0) }
                        } label: {
                            RowLabel(title: "Glass", subtitle: s.glassLevel == .tinted ? "More black, a gentler bend at the edge."
                                     : s.glassLevel == .balanced ? "Black melting into glass, evenly."
                                     : s.glassLevel == .airy ? "Less black, a deeper bend at the edge."
                                     : "Mostly glass: the desktop shows through, magnified at the edge.")
                        }
                        .pickerStyle(.segmented)
                    }
                    Picker(selection: $s.searchBarEffect) {
                        ForEach(AppSettings.SearchBarEffect.allCases) { Text($0.label).tag($0) }
                    } label: {
                        RowLabel(title: "Search bar", subtitle: s.searchBarEffect == .glow ? "Apple Intelligence's colours flow around it as you type and search."
                                 : s.searchBarEffect == .shimmer ? "A white light runs along its edge, without colour."
                                 : "Just the bar, with no glow or motion around it.")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Open notch")
                }
            }
            Section("Motion") {
                Picker(selection: $s.animationStyle) {
                    ForEach(AppSettings.AnimationStyle.allCases) { Text($0.label).tag($0) }
                } label: {
                    RowLabel(title: "Animation", subtitle: s.animationStyle == .snappy ? "Quick and firm, with hardly any overshoot."
                             : s.animationStyle == .bouncy ? "A playful spring as the notch opens and pages slide."
                             : "Gentle springs as the notch opens and pages slide. Reduce Motion in System Settings turns slides into fades.")
                }
                .pickerStyle(.segmented)
                ToggleRow("Shadow when open", subtitle: "A soft shadow under the open notch.", isOn: $s.showShadow)
                ToggleRow("Haptic feedback", subtitle: "A light tap on the trackpad as the notch opens, tabs change and things snap into place.", isOn: $s.haptics)
            }
            Section {
                Picker(selection: $s.alertLevel) {
                    ForEach(AppSettings.AlertLevel.allCases) { Text($0.label).tag($0) }
                } label: {
                    RowLabel(title: "Alerts under the notch",
                             subtitle: "Important keeps only the ones that ask something of you, like a meeting about to start.")
                }
                .pickerStyle(.segmented)
                Picker(selection: $s.notificationMirror) {
                    ForEach(NotificationMirror.Mode.allCases) { Text($0.label).tag($0) }
                } label: {
                    RowLabel(title: "Other apps' notifications",
                             subtitle: "Under the notch instead of the corner, with a reply.")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Alerts")
            } footer: {
                FooterText("Alerts drop down under the notch without moving your Glances, wait while a full-screen app is in front, and stay while the pointer rests on them. Volume, brightness and charging have their own switches. Replies to Messages, WhatsApp, Telegram and other chats are sent without leaving what you're doing.")
            }
        }
    }
}
