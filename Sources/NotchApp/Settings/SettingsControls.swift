import SwiftUI

/// Settings' controls, drawn as iOS and macOS 26 draw theirs, so every page reads like the
/// system's own: a grey track, white knobs and pills, and the Mac's accent colour for whatever is
/// on or filled. One set, used everywhere, instead of a mix of AppKit's older controls.
enum NotchControl {
    /// The page behind the cards: a shade darker than them in both modes, so they need no outline.
    static let page = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.underPageBackgroundColor
            : NSColor(white: 0.885, alpha: 1)
    })
    /// The empty track: the system's fill, which adapts to light and dark.
    static let track = Color.primary.opacity(0.12)
    static let height: CGFloat = 24
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.78)
}

/// The iOS switch: a capsule that fills with the accent colour, and a white pill knob that
/// slides across (and stretches a little while pressed, as iOS's does).
struct NotchSwitchStyle: ToggleStyle {
    /// Just the switch, for a place that has its own label (the page's header).
    var bare = false

    func makeBody(configuration: Configuration) -> some View {
        Switch(configuration: configuration, bare: bare)
    }

    private struct Switch: View {
        let configuration: Configuration
        let bare: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var pressed = false

        var body: some View {
            let on = configuration.isOn
            HStack(alignment: .center) {
                if !bare {
                    configuration.label
                    Spacer(minLength: 12)
                }
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? Color.accentColor : NotchControl.track)
                    Capsule()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .frame(width: pressed ? 28 : 24, height: 18)
                        .padding(2)
                }
                .frame(width: 44, height: 22)
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { withAnimation(.easeOut(duration: 0.12)) { pressed = true } } }
                    .onEnded { _ in
                        withAnimation(NotchControl.spring) { pressed = false; configuration.isOn.toggle() }
                    })
                .opacity(enabled ? 1 : 0.4)
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(on ? "On" : "Off")
                .accessibilityAction { configuration.isOn.toggle() }
            }
        }
    }
}

/// A few choices side by side, as iOS's segmented control: a grey track, the chosen one on a
/// raised pill that slides over to the next one picked.
struct CapsuleChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Namespace private var pill
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let chosen = option == selection
                // A button, not a tap gesture: Form rows don't pass tap gestures their clicks, and
                // text in a row's value is selectable (it took the click, and showed a selection).
                Button {
                    withAnimation(NotchControl.spring) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: NotchControl.height - 4)
                        .background {
                            if chosen {
                                Capsule().fill(scheme == .dark ? Color.white.opacity(0.24) : .white)
                                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .textSelection(.disabled)
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(NotchControl.track))
        .fixedSize()
        .opacity(enabled ? 1 : 0.4)
    }
}

/// A settings row with a capsule choice on the right.
struct ChoiceRow<Value: Hashable, Label: View>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @ViewBuilder var label: Label

    var body: some View {
        LabeledContent {
            CapsuleChoice(selection: $selection, options: options, title: title)
        } label: {
            label
        }
    }
}

extension ChoiceRow where Label == Text {
    init(_ name: String, selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        self.init(selection: selection, options: options, title: title) { Text(name) }
    }
}

/// A level, as iOS's slider: a thin grey track filling with the accent colour, a white knob at
/// the end of the fill, dragged or clicked anywhere along it. Stops, if given, are dots on the track.
struct CapsuleSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var stops: [Double] = []
    var step: Double? = nil
    /// Nil to take the row's width.
    var width: CGFloat? = 220
    @Environment(\.isEnabled) private var enabled
    @State private var dragging = false

    private static let knob: CGFloat = 20, track: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let run = max(1, geo.size.width - Self.knob)
            let x = { (v: Double) -> CGFloat in Self.knob / 2 + run * CGFloat(span > 0 ? (v - range.lowerBound) / span : 0) }
            let at = x(value)
            ZStack(alignment: .leading) {
                Capsule().fill(NotchControl.track)
                    .frame(height: Self.track)
                Capsule().fill(Color.accentColor)
                    .frame(width: at, height: Self.track)
                ForEach(stops, id: \.self) { stop in
                    Circle().fill(stop <= value ? Color.white.opacity(0.7) : Color.primary.opacity(0.35))
                        .frame(width: 4, height: 4)
                        .position(x: x(stop), y: geo.size.height / 2)
                }
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.28), radius: dragging ? 3 : 2, y: 1)
                    .frame(width: Self.knob, height: Self.knob)
                    .scaleEffect(dragging ? 1.1 : 1)
                    .position(x: at, y: geo.size.height / 2)
                    .animation(.easeOut(duration: 0.12), value: dragging)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    let f = min(1, max(0, (g.location.x - Self.knob / 2) / run))
                    var v = range.lowerBound + Double(f) * span
                    if let step { v = (v / step).rounded() * step }
                    value = min(range.upperBound, max(range.lowerBound, v))
                }
                .onEnded { _ in dragging = false })
        }
        .frame(width: width, height: NotchControl.height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            let delta = step ?? (range.upperBound - range.lowerBound) / 20
            value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? delta : -delta)))
        }
    }
}

/// A count in a capsule, one less or one more either side of it.
struct CapsuleStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let text: (Int) -> String

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > range.lowerBound) { value -= 1 }
            Text(text(value))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 56)
                .textSelection(.disabled)
            stepButton("plus", enabled: value < range.upperBound) { value += 1 }
        }
        .padding(2)
        .background(Capsule().fill(NotchControl.track))
        .fixedSize()
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
                .frame(width: 26, height: NotchControl.height - 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Buttons as the system's grey ones (iOS's tinted gray), or (prominent, the one thing a page wants
/// you to do) filled with the accent colour.
struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Drawn(configuration: configuration, prominent: prominent)
    }

    private struct Drawn: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: NotchControl.height + 2)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Color.accentColor : Color.primary.opacity(hovering ? 0.16 : 0.1)))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .onHover { hovering = $0 }
                .fixedSize()
                // In a Form row's value, text is selectable and would take the click.
                .textSelection(.disabled)
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static var capsule: CapsuleButtonStyle { CapsuleButtonStyle() }
    static var capsuleProminent: CapsuleButtonStyle { CapsuleButtonStyle(prominent: true) }
}
