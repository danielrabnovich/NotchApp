import SwiftUI

/// What clicking a Banner does: take you to what it's about, or simply dismiss it.
@MainActor
enum BannerActions {
    static func perform(_ banner: SneakPeek, in vm: NotchViewModel) {
        ActivityCenter.shared.dismissBanner()
        switch banner {
        case .screenshot, .taildrop:
            UserDefaults.standard.set(ShelfPane.shelf.rawValue, forKey: "shelf.pane")
            vm.open(tab: .shelf, takeKeyboard: false, reason: .click)
        case .download:
            UserDefaults.standard.set(ShelfPane.downloads.rawValue, forKey: "shelf.pane")
            vm.open(tab: .shelf, takeKeyboard: false, reason: .click)
        case .assistant:
            vm.open(tab: .ask, reason: .click)
        case .timer:
            vm.open(tab: .timer, takeKeyboard: false, reason: .click)
        case .meeting:
            NotchPresenter.shared.reopenPending()
        case let .notice(_, _, _, tone) where tone == .action:
            NotchPresenter.shared.reopenPending()
        case let .message(id, _, _, _, _, _):
            if let item = NotificationMirror.shared.item(id) { NotchPresenter.shared.presentReply(to: item) }
        default:
            break // informational: the click just clears it
        }
    }
}

/// Live activities shown on either side of the hardware notch.
struct CollapsedNotchView: View {
    /// The coordinates a peek's caret and the Glance it points at are both measured in.
    static let space = "collapsedNotch"
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var media: MediaController
    @EnvironmentObject private var activity: ActivityCenter
    @EnvironmentObject private var battery: BatteryMonitor
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var shelf: ShelfStore // the stack of quick drops under the notch
    @ObservedObject private var live = LiveActivities.shared

    var body: some View {
        let h = viewModel.notchSize.height
        let side = viewModel.sideWidth

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading
                    .frame(width: side, height: h)
                Color.clear
                    .frame(width: viewModel.notchSize.width, height: h)
                trailing
                    .frame(width: side, height: h)
            }
            if let banner = activity.banner {
                bannerCard(banner)
                    .frame(height: ActivityCenter.bannerHeight)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                                            removal: .opacity.animation(.easeOut(duration: 0.12))))
            } else if viewModel.showsGlancePeek, let item = viewModel.peekedGlance {
                // As wide as the notch is (the Glances may have made it wide), so the details fit.
                GlancePeekCard(item: item, anchorX: viewModel.peekAnchorX)
                    .frame(maxWidth: cardWidth)
                    .frame(maxWidth: .infinity)
                    .frame(height: GlancePeekCard.height)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.08)),
                                            removal: .opacity.animation(.easeOut(duration: 0.1))))
            } else if CaptionStrip.shared.showing {
                CaptionStripView()
                    .frame(maxWidth: max(viewModel.notchSize.width + 360, viewModel.notchSize.width + 2 * viewModel.sideWidth - 40))
                    .frame(maxWidth: .infinity)
                    .frame(height: CaptionStrip.height)
                    .transition(.opacity)
            } else if let reminder = activity.reminder {
                reminderTab(reminder)
                    .frame(height: ActivityCenter.reminderHeight)
                    .transition(.opacity)
            }
            if viewModel.showsStack {
                ShelfStackRow(viewModel: viewModel)
                    .frame(height: NotchViewModel.stackHeight)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: Self.space)
    }

    // MARK: - Sides

    @ViewBuilder private var leading: some View {
        switch viewModel.activity {
        case .none:
            Color.clear
        case .music:
            AlbumArtView(image: media.artwork, size: viewModel.notchSize.height - 10, cornerRadius: 5)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .videoDownload:
            VideoDownloadRing()
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .speedTest:
            Image(systemName: "speedometer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SpeedTest.shared.phase == .upload ? ToolsPalette.up : ToolsPalette.down)
                .symbolEffect(.pulse, options: .repeating)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .working:
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .symbolEffect(.pulse, options: .repeating)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .tasks:
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .timer:
            TimerRing(clock: TimerStore.shared.clock)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .live:
            LiveSide(row: viewModel.glanceRow(.left), side: .left, viewModel: viewModel)
                .transition(.blurReplace)
        case .peek:
            if let peek = activity.peek { peekLeading(peek).transition(.blurReplace) }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch viewModel.activity {
        case .none:
            Color.clear
        case .videoDownload:
            VideoDownloadPercent()
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .speedTest:
            LiveSpeedReadout()
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .working:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .tasks:
            TaskCountBadge(count: viewModel.taskBadgeCount ?? 0)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .timer:
            TimerReadout(clock: TimerStore.shared.clock)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .music:
            HStack(spacing: 6) {
                if settings.showVisualizer {
                    AudioVisualizer(color: settings.accent(for: media), isPlaying: media.isPlaying, barCount: 4)
                        .frame(width: 18, height: 13)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(settings.accent(for: media))
                }
                if let count = viewModel.taskBadgeCount {
                    TaskCountBadge(count: count)
                }
            }
            .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .live:
            LiveSide(row: viewModel.glanceRow(.right), side: .right, viewModel: viewModel)
                .transition(.blurReplace)
        case .peek:
            if let peek = activity.peek { peekTrailing(peek).transition(.blurReplace) }
        }
    }

    @ViewBuilder private func peekLeading(_ peek: SneakPeek) -> some View {
        switch peek {
        case let .volume(level, muted):
            let silent = muted || level <= 0.001
            FlashReadout(icon: Self.outputIcon(muted: silent), variable: silent ? nil : Double(level), level: level, muted: muted)
        case let .brightness(level):
            FlashReadout(icon: level < 0.5 ? "sun.min.fill" : "sun.max.fill", level: level)
        case .charging:
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Charging")
                    .foregroundStyle(.white.opacity(0.9))
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
        case let .window(icon, _):
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
        case let .meeting(_, _, color):
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: color))
        case .screenshot:
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        case .timer:
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TimerPalette.accent)
                .symbolEffect(.pulse)
        case .download:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.blue)
        case let .notice(_, _, icon, tone):
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone == .warning || icon == "mic.fill" ? Color.orange : icon == "video.fill" ? .green : .white)
        case .taildrop:
            if let icon = SystemIcons.tailscale {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TaildropPalette.accent)
            }
        case let .assistant(_, _, isWeb):
            Image(systemName: isWeb ? "globe" : "doc.text.magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        case let .message(_, _, bundleID, _, _, _):
            if let id = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                AppIcon(bundlePath: url.path, size: 24)
            } else {
                Image(systemName: "bell.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder private func peekTrailing(_ peek: SneakPeek) -> some View {
        switch peek {
        case let .volume(level, muted):
            FlashBar(value: Double(level), color: flashColor, dimmed: muted)
        case let .brightness(level):
            FlashBar(value: Double(level), color: flashColor)
        case let .charging(level):
            HStack(spacing: 5) {
                Text("\(level)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                BatteryIcon(level: level, charging: true, animated: true)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
        case let .window(_, label):
            Text(label)
                .font(.system(size: label.count == 1 ? 14 : 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
        case let .meeting(_, minutes, color):
            Text("\(minutes)m")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Color(nsColor: color))
        case .screenshot:
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        case .timer:
            Image(systemName: "bell.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TimerPalette.accent)
        case .download:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
        case let .notice(_, _, _, tone):
            switch tone {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
            case .warning:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
            case .info:
                Circle().fill(.white.opacity(0.75)).frame(width: 6, height: 6)
            case .action:
                // Open the notch for the buttons.
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .symbolEffect(.bounce, options: .repeat(2))
            }
        case let .taildrop(title, _, _):
            Image(systemName: title.hasPrefix("Couldn't") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(title.hasPrefix("Couldn't") ? Color.orange : Color.green)
        case let .assistant(title, _, _):
            Image(systemName: title.hasPrefix("No") || title.hasSuffix("failed") ? "questionmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(title.hasPrefix("No") || title.hasSuffix("failed") ? Color.orange : Color.green)
                .symbolEffect(.bounce, value: title)
        case let .message(_, _, _, _, _, replyable):
            // Click to answer (or, without a reply, to open it).
            Image(systemName: replyable ? "arrowshape.turn.up.left.circle.fill" : "chevron.down.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    // MARK: - Banners

    /// A heads-up dropped down under the notch: its glyph, two lines, and its mark (a check, a
    /// warning, or a chevron when it has buttons). Click to act on it; resting on it keeps it up.
    private func bannerCard(_ banner: SneakPeek) -> some View {
        let text = banner.bannerText
        return HStack(spacing: 11) {
            Group {
                // An app's own icon stands on its own; a glyph sits in a soft disc.
                if case let .message(_, _, bundleID, _, _, _) = banner, let id = bundleID,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    AppIcon(bundlePath: url.path, size: 32)
                } else {
                    peekLeading(banner)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(text.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(text.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            peekTrailing(banner)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.bottom, 6)
        // Centred under the notch and as wide as the Glances make it, so the text has the room.
        .frame(maxWidth: cardWidth)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            BannerActions.perform(banner, in: viewModel)
        }
    }

    /// An unanswered Prompt, folded into a slim tab: click to bring its buttons back.
    private func reminderTab(_ title: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color.orange).frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            NotchPresenter.shared.reopenPending()
        }
        .help("Show again")
    }

    private struct TaskCountBadge: View {
        let count: Int
        var body: some View {
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .frame(minWidth: 17, minHeight: 17)
                .background(Capsule().fill(.white.opacity(0.92)))
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: count)
        }
    }

    /// The width a Banner or peek gets under the notch: the notch's own, less its rounded corners.
    private var cardWidth: CGFloat {
        max(ActivityCenter.bannerWidth(notchWidth: viewModel.notchSize.width), viewModel.notchSize.width + 2 * viewModel.sideWidth - 40)
    }

    private var flashColor: Color { settings.accentMode == .custom ? settings.customAccent : .white }

    /// The speaker (its waves lit to the level by the caller), or the headphones playing, as on
    /// iPhone: AirPods show as AirPods.
    @MainActor static func outputIcon(muted: Bool) -> String {
        if muted { return "speaker.slash.fill" }
        if let device = AudioOutputManager.shared.current, device.icon != "laptopcomputer", device.icon != "hifispeaker",
           device.icon.contains("airpods") || device.icon.contains("headphones") || device.icon.contains("beats") {
            return device.icon
        }
        return "speaker.wave.3.fill"
    }

    static func volumeIcon(level: Float, muted: Bool) -> String {
        if muted || level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// Phase icon inside a ring that fills as the countdown runs (beside the notch).
struct TimerRing: View {
    @ObservedObject var clock: TimerClock
    @EnvironmentObject private var store: TimerStore

    var body: some View {
        let color = TimerPalette.color(for: store)
        let icon = store.runningMode == .pomodoro ? store.phase.icon : store.runningMode.icon
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2)
            if store.runningMode != .stopwatch {
                Circle()
                    .trim(from: 0, to: store.progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: 18, height: 18)
        .opacity(store.state == .paused ? 0.5 : 1)
    }
}

struct TimerReadout: View {
    @ObservedObject var clock: TimerClock
    @EnvironmentObject private var store: TimerStore

    var body: some View {
        Text(store.displayTime)
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(store.state == .paused ? .white.opacity(0.5) : TimerPalette.color(for: store))
            .lineLimit(1)
            .fixedSize()
    }
}

/// The live speed beside the notch during a speed test (its own view, so only it redraws each second).
private struct LiveSpeedReadout: View {
    @ObservedObject private var network = NetworkMonitor.shared
    @ObservedObject private var speed = SpeedTest.shared

    var body: some View {
        Text(speed.phase == .connecting ? "…" : formatMbps(speed.liveSpeed))
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .fixedSize()
    }
}

/// The download in progress as a ring with the video glyph inside.
private struct VideoDownloadRing: View {
    @ObservedObject private var videos = VideoDownloader.shared

    var body: some View {
        let job = videos.current
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: max(0.02, job?.progress ?? 0))
                .stroke(Color.red, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: job?.format == .audio ? "music.note" : "play.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 17, height: 17)
        .help(job?.displayTitle ?? "")
    }
}

private struct VideoDownloadPercent: View {
    @ObservedObject private var videos = VideoDownloader.shared

    var body: some View {
        let job = videos.current
        Text(job?.state == .processing ? "…" : job.map { "\(Int(($0.progress * 100).rounded()))%" } ?? "")
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.92))
            .fixedSize()
    }
}

/// The outer left of a volume or brightness Flash: the glyph (a speaker's waves lit to the level)
/// and the percent, rolling as it changes.
private struct FlashReadout: View {
    let icon: String
    var variable: Double? = nil
    let level: Float
    var muted = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon, variableValue: variable)
                .font(.system(size: 13, weight: .semibold))
                // Muted, like 🔇: the slash red, the speaker white.
                .symbolRenderingMode(.palette)
                .foregroundStyle(icon.contains(".slash") ? Color(red: 1, green: 0.27, blue: 0.23) : .white, .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
            Text(muted ? "Muted" : "\(Int((level * 100).rounded()))")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(muted ? 0.5 : 0.9))
                .contentTransition(.numericText(value: Double(level)))
                .fixedSize()
        }
        .animation(.snappy(duration: 0.22), value: level)
        .animation(.snappy(duration: 0.22), value: icon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
    }
}

/// The outer right of a volume or brightness Flash: a bar that stretches with the wing it has
/// (up to a comfortable length), with a soft glow on the fill; grey while muted.
private struct FlashBar: View {
    let value: Double
    let color: Color
    var dimmed = false

    var body: some View {
        GeometryReader { geo in
            let fill = min(1, max(0, value))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule()
                    .fill(dimmed ? Color.white.opacity(0.35) : color)
                    .frame(width: fill > 0 ? max(6, fill * geo.size.width) : 0)
                    .shadow(color: color.opacity(dimmed ? 0 : 0.5), radius: 4)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: fill)
            .animation(.easeOut(duration: 0.2), value: dimmed)
        }
        .frame(maxWidth: 180)
        .frame(height: 6)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 14)
    }
}
