import SwiftUI

struct OpenNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var battery: BatteryMonitor
    @EnvironmentObject private var activity: ActivityCenter

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: viewModel.notchSize.height)
            ZStack {
                if let overlay = viewModel.overlay {
                    OverlayView(overlay: overlay)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                } else if viewModel.mirror {
                    MirrorView(viewModel: viewModel)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                } else {
                PagedTabsView(viewModel: viewModel)
                    .opacity(viewModel.isDragActive ? 0 : 1)
                    .scaleEffect(viewModel.isDragActive ? 0.96 : 1)
                if viewModel.isDragActive {
                    DropZonesView(viewModel: viewModel)
                        .transition(.scale(scale: 1.04).combined(with: .opacity))
                }
                }
            }
            .animation(Motion.pane.animation, value: viewModel.overlay)
            .animation(Motion.pane.animation, value: viewModel.mirror)
            .animation(Motion.pane.animation, value: viewModel.isDragActive)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 0) {
            TabIndicator(viewModel: viewModel)
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: viewModel.notchSize.width + 16)

            // Volume and brightness show here while the notch is open (the closed notch's wings,
            // where they'd usually appear, are covered), in place of the battery and buttons.
            // The status items stay in place underneath (faded), rather than being taken out and
            // put back, so they come back exactly as they were.
            // A tab picked from the keyboard shows its name here the same way, briefly.
            let flash = activity.peek.flatMap { $0.kind == .volume || $0.kind == .brightness ? $0 : nil }
            let tabName = flash == nil ? viewModel.tabFlash : nil
            let covered = flash != nil || tabName != nil
            ZStack(alignment: .trailing) {
                statusItems
                    .opacity(covered ? 0 : 1)
                    .blur(radius: covered ? 6 : 0)
                    .allowsHitTesting(!covered)
                if let flash {
                    HeaderFlash(peek: flash)
                        .transition(.blurReplace)
                } else if let tabName {
                    HStack(spacing: 6) {
                        Image(systemName: tabName.icon).font(.system(size: 11, weight: .semibold))
                        Text(tabName.title).font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(height: 24)
                    .padding(.trailing, 4)
                    .id(tabName)
                    .transition(.blurReplace)
                }
            }
            .animation(.snappy(duration: 0.25), value: flash == nil)
            .animation(.snappy(duration: 0.25), value: tabName)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
    }

    /// The battery, the camera mirror and Settings, on the right of the notch.
    private var statusItems: some View {
            HStack(spacing: 8) {
                if battery.hasBattery {
                    HStack(spacing: 5) {
                        Text("\(battery.level)%")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                        BatteryIcon(level: battery.level, charging: battery.isCharging || battery.isPluggedIn,
                                    lowPower: battery.lowPowerMode)
                    }
                }
                if settings.cameraMirrorEnabled {
                    Button {
                        withAnimation(Motion.pane.animation) { viewModel.mirror.toggle() }
                    } label: {
                        Image(systemName: viewModel.mirror ? "web.camera.fill" : "web.camera")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(viewModel.mirror ? 1 : 0.7))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 24))
                    .help("Camera mirror")
                }
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(NotchIconButtonStyle(size: 24))
            }
    }
}

/// Volume or brightness in the open notch's top row: the symbol, a bar and the level, in the
/// same look as the closed notch's Flash.
private struct HeaderFlash: View {
    let peek: SneakPeek
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let (icon, variable, level, muted): (String, Double?, Float, Bool) = {
            switch peek {
            case let .volume(level, muted):
                let silent = muted || level <= 0.001
                return (CollapsedNotchView.outputIcon(muted: silent), silent ? nil : Double(level), level, muted)
            case let .brightness(level):
                return (level < 0.5 ? "sun.min.fill" : "sun.max.fill", nil, level, false)
            default:
                return ("", nil, 0, false)
            }
        }()
        let color = settings.accentMode == .custom ? settings.customAccent : .white
        let fill = CGFloat(min(1, max(0, level)))
        HStack(spacing: 8) {
            Image(systemName: icon, variableValue: variable)
                .font(.system(size: 12, weight: .semibold))
                // Muted, like 🔇: the slash red, the speaker white.
                .symbolRenderingMode(.palette)
                .foregroundStyle(icon.contains(".slash") ? Color(red: 1, green: 0.27, blue: 0.23) : .white, .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule()
                    .fill(muted ? Color.white.opacity(0.35) : color)
                    .frame(width: fill > 0 ? max(5, fill * 110) : 0)
                    .shadow(color: color.opacity(muted ? 0 : 0.5), radius: 4)
            }
            .frame(width: 110, height: 5)
            .animation(Motion.small.animation, value: fill)
            Text(muted ? "Muted" : "\(Int((level * 100).rounded()))")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(muted ? 0.5 : 0.85))
                .contentTransition(.numericText(value: Double(level)))
                .frame(minWidth: 26, alignment: .trailing)
        }
        .animation(.snappy(duration: 0.22), value: level)
        .frame(height: 24)
        .padding(.trailing, 4)
    }
}

/// Tab buttons with a highlight pill that tracks the swipe continuously.
private struct TabIndicator: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var shelf: ShelfStore
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var assistant: AssistantStore

    private let spacing: CGFloat = 3

    var body: some View {
        let tabs = viewModel.tabs
        // Narrow the buttons as tabs are added so they still fit beside the notch.
        // Fit every tab into the space left of the hardware notch (open width minus the header's
        // side padding and the notch gap, halved); a fixed width pushed the last tab under the notch.
        let available = (viewModel.openSize.width - 28 - viewModel.notchSize.width - 16) / 2
        let buttonWidth = min(40, (available - spacing * CGFloat(max(tabs.count - 1, 0))) / CGFloat(max(tabs.count, 1)))
        if tabs.count > 1 {
            ZStack(alignment: .leading) {
                // The pill and the lit icon inside it, moved by the pager with the pages (Core
                // Animation, one transaction); the buttons above stay dim, and white over white is white.
                TabPill(pager: viewModel.pager, icons: tabs.map(\.icon), buttonWidth: buttonWidth, spacing: spacing,
                        index: viewModel.tabIndex)
                    .frame(width: buttonWidth * CGFloat(tabs.count) + spacing * CGFloat(tabs.count - 1), height: 22)

                HStack(spacing: spacing) {
                    ForEach(tabs) { tab in
                        Button { viewModel.select(tab) } label: {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: buttonWidth, height: 22)
                                .overlay(alignment: .topTrailing) { badge(for: tab, compact: buttonWidth < 28) }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("\(tab.title)  ·  ⌃Tab or ⌘⇧] for the next tab")
                    }
                }
            }
        }
    }

    /// A count over the tab; with many tabs the buttons are narrow, so it becomes a small dot that
    /// doesn't cover the neighbouring icon.
    @ViewBuilder private func badge(for tab: NotchTab, compact: Bool) -> some View {
        let count = tab == .tasks ? tasks.openCount : tab == .shelf ? shelf.items.count : tab == .ask ? assistant.runningCount : 0
        if count > 0, compact {
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: 5, height: 5)
                .offset(x: -1, y: 1)
                .help("\(count)")
        } else if count > 0 {
            Text("\(count)")
                .font(.system(size: 8, weight: .bold).monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 3.5)
                .frame(minWidth: 13, minHeight: 13)
                .background(Capsule().fill(.white.opacity(0.9)))
                .offset(x: 1, y: -3)
                .contentTransition(.numericText())
                .animation(Motion.small.animation, value: count)
        }
    }
}

/// All tabs laid side by side, moved by the pager (see `PagerState`).
private struct PagedTabsView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        PagerHost(viewModel: viewModel, tabs: viewModel.tabs, index: viewModel.tabIndex) { [viewModel] tab in
            switch tab {
            case .home: AnyView(HomeView())
            case .shelf: AnyView(ShelfView(viewModel: viewModel))
            case .tasks: AnyView(TasksTab(viewModel: viewModel))
            case .timer: AnyView(TimerView(viewModel: viewModel))
            case .mixer: AnyView(MixerView(viewModel: viewModel))
            case .controls: AnyView(ControlsView(viewModel: viewModel))
            case .stats: AnyView(StatsView())
            case .tools: AnyView(ToolsView(viewModel: viewModel))
            case .agents: AnyView(AgentsView())
            case .ask: AnyView(AskView(viewModel: viewModel))
            }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var media: MediaController
    /// Music gets the big player when it was playing as Home appeared; otherwise it shrinks to a small
    /// card in the same place and the day takes the room. Decided on appearing, so pausing while you look doesn't
    /// reshuffle the page (starting playback does bring the player back).
    @State private var musicLarge = true
    @ObservedObject private var meetings = MeetingMonitor.shared

    private var showsToday: Bool { settings.calendarEnabled || settings.tasksEnabled }

    var body: some View {
        VStack(spacing: 8) {
            if settings.meetingMode, meetings.call != nil { CallBar() }
            content
        }
        .animation(Motion.pane.animation, value: meetings.call != nil)
    }

    private var content: some View {
        HStack(spacing: 18) {
            if settings.musicEnabled, showsToday, musicLarge {
                // Playing: an even split, fixed, so neither side moves as songs change.
                GeometryReader { geo in
                    let half = (geo.size.width - 37) / 2
                    HStack(spacing: 18) {
                        MusicPlayerView(half: true)
                            .frame(width: half, alignment: .leading)
                        divider
                        TodayPanel(layout: .half)
                            .frame(width: half)
                    }
                }
            } else if settings.musicEnabled, !showsToday {
                MusicPlayerView()
                    .frame(maxWidth: .infinity)
            } else if showsToday {
                // Music keeps its place on the left, small; the day widens into the room it gave up,
                // with the weather in full.
                let compact = settings.musicEnabled && media.hasTrack
                if compact {
                    CompactMusicCard()
                        .frame(width: 170)
                    divider
                }
                TodayPanel(layout: compact ? .full : .roomy)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22))
                    Text("Turn on Music, Calendar or Tasks in Settings")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { musicLarge = media.isPlaying }
        .onChange(of: media.isPlaying) { _, playing in
            if playing, !musicLarge { withAnimation(Motion.pane.animation) { musicLarge = true } }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.1))
            .frame(width: 1)
            .padding(.vertical, 6)
    }
}
