import SwiftUI

struct OpenNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var homeEditing = HomeEditing.shared
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
            let editingHome = homeEditing.active && viewModel.tab == .home && flash == nil && tabName == nil
            let covered = flash != nil || tabName != nil || editingHome
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
                } else if editingHome {
                    HomeEditBar()
                        .transition(.blurReplace)
                }
            }
            .animation(.snappy(duration: 0.25), value: editingHome)
            .animation(.snappy(duration: 0.25), value: flash == nil)
            .animation(.snappy(duration: 0.25), value: tabName)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .onChange(of: viewModel.tab) { _, tab in
            if tab != .home { homeEditing.end() }
        }
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
    @ObservedObject private var weather = TodayWeather.shared
    @ObservedObject private var birthdays = Birthdays.shared
    @ObservedObject private var editing = HomeEditing.shared
    /// The card being dragged in edit mode, and how far.
    @State private var dragging: HomeCard?
    @State private var dragOffset: CGFloat = 0
    @ObservedObject private var devices = DeviceBatteries.shared
    @EnvironmentObject private var battery: BatteryMonitor
    /// Debug (`homeshot`): music's size and a call, instead of what's going on.
    var shot: HomeShot?

    private var showsToday: Bool { settings.calendarEnabled || settings.tasksEnabled }

    var body: some View {
        VStack(spacing: 8) {
            if let call = shot?.call { CallBar(preview: call) }
            else if shot == nil, settings.meetingMode, meetings.call != nil { CallBar() }
            content
        }
        .animation(Motion.pane.animation, value: meetings.call != nil)
    }

    private var content: some View {
        GeometryReader { geo in
            let entries = shot?.cards ?? settings.homeCards
            let columns = HomeTiler.tile(entries, width: geo.size.width, height: geo.size.height, wanted: wanted)
            let all = columns.flatMap(\.cards)
            let fit = HomeFit.fitting(height: geo.size.height, birthday: !birthdays.today.isEmpty)
            let waiting = entries.map(\.card).filter { card in wanted(card) != nil && !all.contains { $0.card == card } }
            Group {
                if isEditing, shot == nil, editing.adding {
                    HomeCardGallery()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .transition(.opacity)
                } else if columns.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 22))
                        Text(isEditing ? "Add cards with the + above" : entries.isEmpty ? "Right-click to add cards to Home" : "Turn on Music, Calendar or Tasks in Settings")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    row(columns, all: all, fit: fit, size: geo.size)
                }
            }
            .onChange(of: waiting, initial: true) { _, waiting in
                if shot == nil { editing.waiting = waiting }
            }
        }
        .contextMenu {
            if shot == nil {
                Button(isEditing ? "Done Editing" : "Edit Home…") { isEditing ? editing.end() : editing.begin() }
            }
        }
        .onAppear { musicLarge = shot.map { $0.music == .large } ?? media.isPlaying }
        .onChange(of: media.isPlaying) { _, playing in
            if playing, !musicLarge, shot == nil { withAnimation(Motion.pane.animation) { musicLarge = true } }
        }
    }

    private var isEditing: Bool { shot?.editing ?? editing.active }

    private func row(_ columns: [HomeTiler.Column], all: [HomeTiler.Placed], fit: HomeFit, size: CGSize) -> some View {
        // The fixed columns first; the rest share what they leave.
        let flexible = columns.filter { $0.width == nil }.count
        let left = size.width - columns.reduce(0) { $0 + $1.gap + ($1.width ?? 0) }
        let widths = columns.map { $0.width ?? max(0, left) / CGFloat(max(1, flexible)) }
        // Each column's middle, for where a dragged card lands.
        var middles: [CGFloat] = []
        var x: CGFloat = 0
        for (column, width) in zip(columns, widths) {
            x += column.gap
            middles.append(x + width / 2)
            x += width
        }
        return HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { i, column in
                if i > 0 {
                    ZStack {
                        if !isEditing { rule(between: columns[i - 1].cards[0], and: column.cards[0], fit: fit) }
                    }
                    .frame(width: column.gap, height: size.height)
                }
                Group {
                    if let item = column.cards.first, column.cards.count == 1 {
                        editable(card(item, in: all, fit: fit, columns: columns.count), item.card, from: i, columns: columns, middles: middles)
                            .frame(width: widths[i], height: size.height,
                                   alignment: item.card == .music && item.size == .large ? .leading : .center)
                    } else {
                        // Two half-height tiles stacked, a rule between.
                        VStack(spacing: 0) {
                            ForEach(Array(column.cards.enumerated()), id: \.element.card) { j, item in
                                if j > 0 {
                                    ZStack {
                                        if !isEditing { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
                                    }
                                    .frame(height: HomeTiler.stackGap)
                                }
                                editable(card(item, in: all, fit: fit, columns: columns.count), item.card, from: i, columns: columns, middles: middles)
                                    .frame(width: widths[i], height: (size.height - HomeTiler.stackGap) / 2)
                            }
                        }
                        .frame(width: widths[i], height: size.height)
                    }
                }
                .zIndex(column.cards.contains { $0.card == dragging } ? 1 : 0)
            }
        }
    }

    /// A card, decorated for edit mode and following a drag.
    private func editable(_ view: some View, _ card: HomeCard, from column: Int, columns: [HomeTiler.Column], middles: [CGFloat]) -> some View {
        let entry = (shot?.cards ?? settings.homeCards).first { $0.card == card } ?? HomeEntry(card: card)
        return view
            .modifier(HomeEditDecoration(entry: entry, editing: isEditing,
                                         onDrag: { dx in dragging = card; dragOffset = dx },
                                         onDrop: { dx in drop(card, from: column, by: dx, columns: columns, middles: middles) }))
            .offset(x: dragging == card ? dragOffset : 0)
            .scaleEffect(dragging == card ? 1.03 : 1)
    }

    /// Moves a dragged card to the column nearest where it was let go: before that column's cards
    /// when it went left, after them when it went right.
    private func drop(_ card: HomeCard, from column: Int, by dx: CGFloat, columns: [HomeTiler.Column], middles: [CGFloat]) {
        let landed = middles[column] + dx
        let target = middles.indices.min { abs(middles[$0] - landed) < abs(middles[$1] - landed) } ?? column
        withAnimation(Motion.pane.animation) {
            dragging = nil
            dragOffset = 0
            guard target != column, let from = settings.homeCards.firstIndex(where: { $0.card == card }) else { return }
            let right = target > column
            let anchor = right ? columns[target].cards.last!.card : columns[target].cards.first!.card
            let entry = settings.homeCards.remove(at: from)
            guard let at = settings.homeCards.firstIndex(where: { $0.card == anchor }) else {
                settings.homeCards.insert(entry, at: from)
                return
            }
            settings.homeCards.insert(entry, at: right ? at + 1 : at)
        }
    }

    /// The size each card wants right now, nil when it has nothing to show. Music: half of Home
    /// while playing (if it takes over), a small card while paused, gone with nothing to play
    /// (unless it's all Home has); the weather only beside the day, once it's in.
    private func wanted(_ card: HomeCard) -> HomeCardSize? {
        switch card {
        case .music:
            let hasTrack = shot.map { $0.music != .none } ?? media.hasTrack
            guard settings.musicEnabled, hasTrack || !showsToday else { return nil }
            return settings.homeMusicTakesOver && musicLarge ? .large : .medium
        case .today:
            return showsToday ? .medium : nil
        case .weather:
            return showsToday && (weather.report != nil || weather.loading) ? .medium : nil
        case .stats:
            return settings.statsEnabled ? .medium : nil
        case .batteries:
            return battery.hasBattery || !devices.devices.isEmpty ? .medium : nil
        case .clock:
            return .medium
        case .agents:
            return settings.agentsEnabled ? .medium : nil
        case .shelf:
            return settings.shelfEnabled ? .medium : nil
        case .timer:
            return settings.timerEnabled ? .medium : nil
        case .clipboard:
            return settings.clipboardHistory ? .medium : nil
        case .unread, .scratchpad, .network, .countdown:
            return .medium
        }
    }

    @ViewBuilder private func card(_ item: HomeTiler.Placed, in placed: [HomeTiler.Placed], fit: HomeFit, columns: Int) -> some View {
        switch item.card {
        case .music:
            if placed.count == 1 { MusicPlayerView() }
            else if item.size == .large { MusicPlayerView(half: true) }
            // Among tiles (four columns or more), stacked down the middle like they are.
            else if item.size == .medium { CompactMusicCard(centered: columns >= 4) }
            else { MusicTile() }
        case .today:
            // Beside the big player it's half of Home; beside the small card, the day in full;
            // alone, roomy enough for the tasks in a column of their own.
            let music = placed.first { $0.card == .music }
            TodayPanel(layout: music == nil ? .roomy : music?.size == .large ? .half : .full, fit: fit)
        case .weather:
            if let report = weather.report {
                HomeWeatherCard(report: report, fit: fit, small: item.size == .small)
                    .transition(.opacity)
            } else {
                WeatherSkeleton(fit: fit, small: item.size == .small)
                    .transition(.opacity)
            }
        case .stats: StatsCard(small: item.size == .small)
        case .batteries: BatteriesCard(small: item.size == .small)
        case .clock: ClockCard(small: item.size == .small)
        case .agents: AgentsCard(small: item.size == .small)
        case .shelf: ShelfCard(small: item.size == .small)
        case .timer: TimerCard(small: item.size == .small)
        case .clipboard: ClipboardCard(small: item.size == .small)
        case .unread: UnreadCard(small: item.size == .small)
        case .scratchpad: ScratchpadCard()
        case .network: NetworkCard(small: item.size == .small)
        case .countdown: CountdownCard(small: item.size == .small)
        }
    }

    /// The rule between two cards. The day and the weather share a header line, so the rule
    /// between them starts under it.
    @ViewBuilder private func rule(between a: HomeTiler.Placed, and b: HomeTiler.Placed, fit: HomeFit) -> some View {
        if Set([a.card, b.card]) == [.today, .weather], !a.card.isTile(a.size), !b.card.isTile(b.size) {
            SectionDivider()
                .padding(.top, fit.headerHeight + 10)
        } else {
            divider
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.1))
            .frame(width: 1)
            .padding(.vertical, 6)
    }
}
