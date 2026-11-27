import SwiftUI

struct AppearancePane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .appearance) {
            Section("Color") {
                ChoiceRow(selection: $s.accentMode, options: AppSettings.AccentMode.allCases, title: { $0.label }) {
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
                                             subtitle: material == .black ? "Solid, like the notch itself" : s.lowPower ? "Black while Low Power Mode is on" : "Melts into clear glass",
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
                        GlassSlider(amount: $s.glassAmount)
                    }
                    ChoiceRow(selection: $s.searchBarEffect, options: AppSettings.SearchBarEffect.allCases, title: { $0.label }) {
                        RowLabel(title: "Search bar", subtitle: s.searchBarEffect == .glow ? "Apple Intelligence's colours flow around it as you type and search."
                                 : s.searchBarEffect == .shimmer ? "A white light runs along its edge, without colour."
                                 : "Just the bar, with no glow or motion around it.")
                }
                } header: {
                    Text("Open notch")
                }
            }
            Section("Motion") {
                ChoiceRow(selection: $s.animationStyle, options: AppSettings.AnimationStyle.allCases, title: { $0.label }) {
                    RowLabel(title: "Animation", subtitle: s.animationStyle == .snappy ? "Quick and firm, with hardly any overshoot."
                             : s.animationStyle == .bouncy ? "A playful spring as the notch opens and pages slide."
                             : "Gentle springs as the notch opens and pages slide. Reduce Motion in System Settings turns slides into fades.")
                }
                ChoiceRow(selection: $s.animationSpeed, options: AppSettings.AnimationSpeed.allCases, title: { $0.label }) {
                    RowLabel(title: "Open and close", subtitle: s.animationSpeed == .quick ? "In and out fast, for a quick emoji or calculation."
                             : s.animationSpeed == .relaxed ? "Takes its time opening and closing."
                             : "How fast the notch opens and closes.")
                }
                ToggleRow("Shadow when open", subtitle: "A soft shadow under the open notch.", isOn: $s.showShadow)
                ToggleRow("Haptic feedback", subtitle: "A light tap on the trackpad as the notch opens, tabs change and things snap into place.", isOn: $s.haptics)
            }
            Section {
                ChoiceRow(selection: $s.alertLevel, options: AppSettings.AlertLevel.allCases, title: { $0.label }) {
                    RowLabel(title: "Alerts under the notch",
                             subtitle: "Important keeps only the ones that ask something of you, like a meeting about to start.")
                }
                ChoiceRow(selection: $s.notificationMirror, options: NotificationMirror.Mode.allCases, title: { $0.label }) {
                    RowLabel(title: "Other apps' notifications",
                             subtitle: "Under the notch instead of the corner, with a reply.")
                }
            } header: {
                Text("Alerts")
            } footer: {
                FooterText("Alerts drop down under the notch without moving your Glances, wait while a full-screen app is in front, and stay while the pointer rests on them. Volume, brightness and charging have their own switches. Replies to Messages, WhatsApp, Telegram and other chats are sent without leaving what you're doing.")
            }
        }
    }
}

/// The glass level as a slider: it snaps to Tinted, Balanced, Airy and Clear as it passes them, with
/// a detent on the trackpad, and stops anywhere between, which blends the two levels either side.
private struct GlassSlider: View {
    @Binding var amount: Double
    private static let levels = AppSettings.GlassLevel.allCases
    /// How close to a stop the slider is caught by it.
    private static let pull = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RowLabel(title: "Glass", subtitle: subtitle, shown: true)
            CapsuleSlider(value: Binding(get: { amount }, set: { set($0) }), range: 0...Double(Self.levels.count - 1),
                          stops: Self.levels.map(\.stop), width: nil)
            // The stops' names under the track, each where its stop is; a click jumps there.
            GeometryReader { geo in
                ForEach(Array(Self.levels.enumerated()), id: \.offset) { i, level in
                    Button(level.label) { withAnimation(.easeOut(duration: 0.15)) { set(level.stop) } }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(abs(amount - level.stop) < 0.01 ? .primary : .secondary)
                        .fixedSize()
                        .position(x: x(for: i, width: geo.size.width), y: 7)
                }
            }
            .frame(height: 14)
        }
    }

    /// Snaps onto a stop within `pull` of it, with a detent when it arrives there.
    private func set(_ value: Double) {
        let stop = value.rounded()
        let snapped = abs(value - stop) < Self.pull ? stop : value
        if snapped == stop, amount != stop { Haptics.align() }
        amount = snapped
    }

    /// Where stop `i` sits under the track (its dot, half the track's height in from each end),
    /// the end labels kept inside the row.
    private func x(for i: Int, width: CGFloat) -> CGFloat {
        let inset: CGFloat = 9 // half the knob
        let x = inset + (width - inset * 2) * CGFloat(i) / CGFloat(Self.levels.count - 1)
        return min(max(x, 22), width - 22)
    }

    private var subtitle: String {
        let nearest = AppSettings.GlassLevel(amount: amount)
        guard abs(amount - nearest.stop) < 0.01 else {
            let lower = Self.levels[Int(amount.rounded(.down))], upper = Self.levels[min(3, Int(amount.rounded(.up)))]
            return "Between \(lower.label) and \(upper.label): \(Int(((amount - lower.stop) * 100).rounded()))% of the way to \(upper.label)."
        }
        switch nearest {
        case .tinted: return "More black, a gentler bend at the edge."
        case .balanced: return "Black melting into glass, evenly."
        case .airy: return "Less black, a deeper bend at the edge."
        case .clear: return "Mostly glass: the desktop shows through, magnified at the edge."
        }
    }
}
