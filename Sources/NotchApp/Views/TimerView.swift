import SwiftUI

enum TimerPalette {
    static let accent = Color(red: 1.00, green: 0.60, blue: 0.20)
    static let breakAccent = Color(red: 0.36, green: 0.85, blue: 0.75)

    @MainActor static func color(for store: TimerStore) -> Color {
        store.isActive && store.runningMode == .pomodoro && store.phase != .focus ? breakAccent : accent
    }
}

/// Timer, Pomodoro and stopwatch tab.
struct TimerView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var store: TimerStore

    var body: some View {
        Group {
            if store.isActive {
                RunningTimerView(clock: store.clock)
            } else {
                setup
            }
        }
        .animation(Motion.pane.animation, value: store.isActive)
        .modifier(TabKeyboard(viewModel: viewModel, tab: .timer, handle: handle))
    }

    /// ← → a minute either way (⇧ five), ↩ or Space to start; Space pauses and resumes once it runs.
    private func handle(_ event: NSEvent) -> Bool {
        // Typing in a field (a Pomodoro setting never is one, but to be safe) keeps its keys.
        if event.window?.firstResponder is NSTextView { return false }
        let space = ShelfKey.isSpace(event)
        if store.isActive {
            guard space else { return false }
            store.state == .running ? store.pause() : store.resume()
            return true
        }
        if space || (event.keyCode == 36 && ShelfKey.carbon(event.modifierFlags) == 0) {
            store.start()
            return true
        }
        guard let (step, extend) = ShelfKey.arrow(event), event.keyCode == 123 || event.keyCode == 124 else { return false }
        let by = step * (extend ? 5 : 1)
        switch store.mode {
        case .timer: store.timerMinutes = min(180, max(1, store.timerMinutes + by))
        case .pomodoro: store.focusMinutes = min(90, max(5, store.focusMinutes + by))
        case .stopwatch: return false
        }
        return true
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                ModeTabs(selection: $store.mode)
                    // Its titles on the header line, the underline hanging just below.
                    .offset(y: 3)
                Spacer()
                TimerButton(title: "Start", icon: "play.fill", prominent: true) { store.start() }
            }
            .notchHeaderRow()
            // One frame for every mode, so switching between them changes what's around the time
            // and nothing moves: the time keeps its place and size, and both rows keep their height.
            HStack(alignment: .center, spacing: 14) {
                switch store.mode {
                case .timer:
                    MinuteRuler(value: $store.timerMinutes, range: 1...180, viewModel: viewModel)
                case .pomodoro:
                    MinuteRuler(value: $store.focusMinutes, range: 5...90, viewModel: viewModel)
                case .stopwatch:
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Counts up from zero")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                        Text("Lap while it runs; laps are kept until you reset")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // As wide as the longest time it shows, so the ruler doesn't stretch as it changes.
                ZStack(alignment: .trailing) {
                    BigTime(text: "0:00:00").hidden()
                    BigTime(text: setupTime)
                }
            }
            .frame(height: 62)
            Group {
                switch store.mode {
                case .timer:
                    Presets(value: $store.timerMinutes, options: [1, 3, 5, 10, 15, 30, 45, 60, 90])
                case .pomodoro:
                    HStack(spacing: 0) {
                        SettingStepper(label: "Short break", value: $store.shortBreakMinutes, range: 1...30, unit: "m")
                        SettingStepper(label: "Long break", value: $store.longBreakMinutes, range: 5...60, step: 5, unit: "m")
                        SettingStepper(label: "Long break every", value: $store.sessionsBeforeLongBreak, range: 2...8, unit: "")
                        SettingStepper(label: "Total sessions", value: $store.totalSessions, range: 1...12, unit: "")
                    }
                case .stopwatch:
                    Color.clear
                }
            }
            .frame(height: 40, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var setupTime: String {
        switch store.mode {
        case .timer: TimerStore.format(TimeInterval(store.timerMinutes * 60))
        case .pomodoro: TimerStore.format(TimeInterval(store.focusMinutes * 60))
        case .stopwatch: "00:00"
        }
    }
}

// MARK: - Running

private struct RunningTimerView: View {
    @ObservedObject var clock: TimerClock
    @EnvironmentObject private var store: TimerStore

    var body: some View {
        let color = TimerPalette.color(for: store)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: store.runningMode == .pomodoro ? store.phase.icon : store.runningMode.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if store.state == .paused {
                    Text("Paused")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                controls
            }
            .notchHeaderRow()

            HStack(alignment: .center, spacing: 18) {
                BigTime(text: store.displayTime, size: 50, color: store.state == .paused ? .white.opacity(0.5) : color)
                    .frame(minWidth: 150, alignment: .leading)
                if store.runningMode == .stopwatch {
                    LapList(laps: store.laps)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressTrack(progress: store.progress, color: color)
                            .frame(height: 6)
                        HStack {
                            Text(subtitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                            Spacer()
                            if store.runningMode == .pomodoro {
                                SessionDots(current: store.session, total: store.totalSessions,
                                            inBreak: store.phase != .focus, color: TimerPalette.accent)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var title: String {
        switch store.runningMode {
        case .timer: "Timer · \(store.timerMinutes) min"
        case .pomodoro: "\(store.phase.label) · \(store.session) of \(store.totalSessions)"
        case .stopwatch: "Stopwatch"
        }
    }

    private var subtitle: String {
        guard store.runningMode == .pomodoro else {
            let end = Date().addingTimeInterval(store.displaySeconds)
            return store.state == .running ? "Ends at \(end.formatted(date: .omitted, time: .shortened))" : "Paused"
        }
        guard let next = store.nextPhase else { return "Last session" }
        return "Next: \(next.label.lowercased()) · \(store.minutes(for: next)) min"
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 6) {
            if store.runningMode == .stopwatch {
                TimerButton(title: "Lap", icon: "flag.fill") { store.lap() }
                    .disabled(store.state != .running)
            }
            if store.runningMode == .pomodoro {
                TimerButton(title: "Skip", icon: "forward.end.fill") { store.skip() }
            }
            if store.state == .running {
                TimerButton(title: "Pause", icon: "pause.fill", prominent: true) { store.pause() }
            } else {
                TimerButton(title: "Resume", icon: "play.fill", prominent: true) { store.resume() }
            }
            TimerButton(title: "Reset", icon: "arrow.counterclockwise") { store.reset() }
        }
    }
}

private struct LapList: View {
    let laps: [TimeInterval]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if laps.isEmpty {
                Text("No laps yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
            ForEach(Array(laps.prefix(4).enumerated()), id: \.offset) { i, lap in
                HStack {
                    Text("Lap \(laps.count - i)")
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Text(TimerStore.format(lap))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionDots: View {
    let current: Int
    let total: Int
    let inBreak: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...max(1, total), id: \.self) { i in
                let done = i < current || (i == current && inBreak)
                Circle()
                    .fill(done ? color : .white.opacity(i == current ? 0.5 : 0.15))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

private struct ProgressTrack: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(6, geo.size.width * min(1, max(0, progress))))
            }
        }
    }
}

// MARK: - Setup pieces

private struct ModeTabs: View {
    @Binding var selection: TimerStore.Mode
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 18) {
            ForEach(TimerStore.Mode.allCases) { mode in
                let selected = mode == selection
                Button {
                    withAnimation(Motion.small.animation) { selection = mode }
                } label: {
                    VStack(spacing: 4) {
                        Text(mode.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(selected ? 0.95 : 0.4))
                        ZStack {
                            Capsule().fill(.clear).frame(height: 2)
                            if selected {
                                Capsule().fill(.white).frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TimerButton: View {
    let title: String
    let icon: String
    var prominent = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? TimerPalette.accent : .white.opacity(0.8))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(prominent ? TimerPalette.accent.opacity(hovering ? 0.32 : 0.22)
                                                 : .white.opacity(hovering ? 0.16 : 0.09)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct BigTime: View {
    let text: String
    var size: CGFloat = 40
    var color: Color = TimerPalette.accent

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .light, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct Presets: View {
    @Binding var value: Int
    let options: [Int]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { m in
                let selected = m == value
                Button { value = m } label: {
                    Text(m >= 60 && m % 60 == 0 ? "\(m / 60)h" : m >= 60 ? "\(m / 60)h\(m % 60)" : "\(m)m")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(selected ? TimerPalette.accent : .white.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SettingStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            HStack(spacing: 6) {
                stepButton("minus", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - step) }
                Text("\(value)\(unit)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(TimerPalette.accent)
                    .frame(minWidth: 28)
                stepButton("plus", enabled: value < range.upperBound) { value = min(range.upperBound, value + step) }
            }
            .padding(3)
            .notchSurface(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.7 : 0.2))
        }
        .buttonStyle(NotchIconButtonStyle(size: 18))
        .disabled(!enabled)
    }
}

/// Horizontal tick ruler: scroll or click to pick a number of minutes. The selected tick sits
/// under the pointer; ticks before it glow, ticks after it dim.
private struct MinuteRuler: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @ObservedObject var viewModel: NotchViewModel

    @State private var scrolled: Int?
    /// Where a click-and-drag started: the ruler moves with the pointer, a minute a tick.
    @State private var dragStart: Int?
    private let pitch: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let inset = geo.size.width / 2 - pitch / 2
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(range), id: \.self) { m in
                        tick(m)
                            .frame(width: pitch)
                            .id(m)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(Motion.pane.animation) { scrolled = m } }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, inset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolled, anchor: .center)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                         .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .bottom) {
                Image(systemName: "triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(TimerPalette.accent)
            }
        }
        .frame(height: 62)
        // A trackpad scrolls it; a mouse can grab it, as you'd pull a tape measure.
        .simultaneousGesture(DragGesture(minimumDistance: 3)
            .onChanged { g in
                let start = dragStart ?? scrolled ?? value
                dragStart = start
                let m = min(range.upperBound, max(range.lowerBound, start - Int((g.translation.width / pitch).rounded())))
                if m != scrolled { scrolled = m }
            }
            .onEnded { _ in dragStart = nil })
        .horizontalScrollRegion("timer.ruler", in: viewModel)
        .onAppear { scrolled = value }
        .onChange(of: scrolled) { old, new in
            // A detent for every minute that passes the pointer, a firmer one on each five.
            if let new, let old, new != old { new % 5 == 0 ? Haptics.level() : Haptics.align() }
            if let new, new != value { value = new }
        }
        .onChange(of: value) { _, new in
            if scrolled != new { withAnimation(Motion.pane.animation) { scrolled = new } }
        }
    }

    private func tick(_ m: Int) -> some View {
        let selected = scrolled ?? value
        let major = m % 5 == 0
        let distance = abs(m - selected)
        let opacity = m <= selected ? max(0.45, 1 - Double(distance) * 0.025) : max(0.12, 0.3 - Double(distance) * 0.01)
        return VStack(spacing: 4) {
            Text(major ? "\(m)" : "")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(TimerPalette.accent.opacity(opacity))
                .fixedSize()
                .frame(height: 13)
            Capsule()
                .fill(TimerPalette.accent.opacity(m == selected ? 1 : opacity))
                .frame(width: m == selected ? 3 : 2.5, height: major ? 30 : 22)
                .frame(height: 30, alignment: .center)
            Spacer(minLength: 0)
        }
    }
}
