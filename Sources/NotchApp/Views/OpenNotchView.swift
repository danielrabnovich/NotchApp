import SwiftUI

struct OpenNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var battery: BatteryMonitor

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
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.overlay)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.mirror)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: viewModel.isDragActive)
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

            HStack(spacing: 8) {
                if battery.hasBattery {
                    HStack(spacing: 5) {
                        Text("\(battery.level)%")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                        BatteryIcon(level: battery.level, charging: battery.isCharging || battery.isPluggedIn)
                    }
                }
                if settings.cameraMirrorEnabled {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { viewModel.mirror.toggle() }
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
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
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
            let progress = CGFloat(viewModel.tabIndex) - viewModel.pageOffset / max(viewModel.pageWidth, 1)
            ZStack(alignment: .leading) {
                Color.clear
                    .notchSurface(Capsule(), active: true)
                    .frame(width: buttonWidth, height: 22)
                    .offset(x: progress * (buttonWidth + spacing))

                HStack(spacing: spacing) {
                    ForEach(Array(tabs.enumerated()), id: \.element) { i, tab in
                        let closeness = max(0, 1 - abs(progress - CGFloat(i)))
                        Button { viewModel.select(tab) } label: {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45 + 0.55 * closeness))
                                .frame(width: buttonWidth, height: 22)
                                .overlay(alignment: .topTrailing) { badge(for: tab) }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private func badge(for tab: NotchTab) -> some View {
        let count = tab == .tasks ? tasks.openCount : tab == .shelf ? shelf.items.count : tab == .ask ? assistant.runningCount : 0
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 8, weight: .bold).monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 3.5)
                .frame(minWidth: 13, minHeight: 13)
                .background(Capsule().fill(.white.opacity(0.9)))
                .offset(x: 1, y: -3)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3), value: count)
        }
    }
}

/// All tabs laid side by side; the row slides to follow the trackpad.
private struct PagedTabsView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let tabs = viewModel.tabs
            let index = CGFloat(viewModel.tabIndex)

            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element) { i, tab in
                    // 0 when centred, 1 when a full page away.
                    let distance: CGFloat = min(1, abs((CGFloat(i) - index) * w + viewModel.pageOffset) / max(w, 1))
                    page(tab)
                        .frame(width: w, height: geo.size.height)
                        .scaleEffect(1 - 0.06 * distance)
                        .opacity(Double(1 - 0.65 * distance))
                }
            }
            .offset(x: -index * w + viewModel.pageOffset)
            .frame(width: w, height: geo.size.height, alignment: .leading)
            .clipped()
            .onAppear { viewModel.pageWidth = w }
            .onChange(of: w) { _, new in viewModel.pageWidth = new }
        }
    }

    @ViewBuilder private func page(_ tab: NotchTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .shelf: ShelfView(viewModel: viewModel)
        case .tasks: TasksTab(viewModel: viewModel)
        case .timer: TimerView(viewModel: viewModel)
        case .mixer: MixerView(viewModel: viewModel)
        case .controls: ControlsView(viewModel: viewModel)
        case .stats: StatsView()
        case .ask: AskView(viewModel: viewModel)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 18) {
            if settings.musicEnabled {
                MusicPlayerView()
                    .frame(maxWidth: .infinity)
            }
            if settings.musicEnabled && settings.calendarEnabled {
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(width: 1)
                    .padding(.vertical, 6)
            }
            if settings.calendarEnabled {
                CalendarPanel()
                    .frame(width: settings.musicEnabled ? 190 : nil)
                    .frame(maxWidth: settings.musicEnabled ? nil : .infinity)
            }
            if !settings.musicEnabled && !settings.calendarEnabled {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22))
                    Text("Turn on Music or Calendar in Settings")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
