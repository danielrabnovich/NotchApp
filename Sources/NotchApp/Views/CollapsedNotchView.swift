import SwiftUI

/// Live activities shown on either side of the hardware notch.
struct CollapsedNotchView: View {
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
            if let peek = activity.peek, peek.kind.hasSubtitle {
                subtitle(for: peek)
                    .frame(height: 26)
                    .transition(.opacity)
            }
            if viewModel.showsStack {
                ShelfStackRow(viewModel: viewModel)
                    .frame(height: NotchViewModel.stackHeight)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            LiveSide(items: live.left, side: .left, notchHeight: viewModel.notchSize.height)
                .transition(.opacity)
        case .peek:
            if let peek = activity.peek { peekLeading(peek).transition(.opacity) }
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
            LiveSide(items: live.right, side: .right, notchHeight: viewModel.notchSize.height)
                .transition(.opacity)
        case .peek:
            if let peek = activity.peek { peekTrailing(peek).transition(.opacity) }
        }
    }

    @ViewBuilder private func peekLeading(_ peek: SneakPeek) -> some View {
        switch peek {
        case let .volume(level, muted):
            Image(systemName: Self.volumeIcon(level: level, muted: muted))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
        case .brightness:
            Image(systemName: "sun.max.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
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
        }
    }

    @ViewBuilder private func peekTrailing(_ peek: SneakPeek) -> some View {
        switch peek {
        case let .volume(level, _):
            LevelBar(value: Double(level), color: settings.accentMode == .custom ? settings.customAccent : .white)
                .frame(width: 44)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
        case let .brightness(level):
            LevelBar(value: Double(level), color: settings.accentMode == .custom ? settings.customAccent : .white)
                .frame(width: 44)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
        case let .charging(level):
            HStack(spacing: 5) {
                Text("\(level)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                BatteryIcon(level: level, charging: true, animated: true)
            }
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
        }
    }

    @ViewBuilder private func subtitle(for peek: SneakPeek) -> some View {
        switch peek {
        case let .meeting(title, minutes, _):
            Text("\(title) · in \(minutes) min" + (NotchPresenter.shared.hasPendingPrompt(titled: title) ? " · open to join" : ""))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        case let .notice(title, detail, _, _):
            (Text(title).fontWeight(.semibold) + Text(" · " + detail).foregroundColor(.white.opacity(0.7)))
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        case let .taildrop(title, detail, _):
            (Text(title).fontWeight(.semibold) + Text(" · " + detail).foregroundColor(.white.opacity(0.7)))
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        case let .assistant(title, detail, _):
            (Text(title).fontWeight(.semibold) + Text(" · " + detail).foregroundColor(.white.opacity(0.7)))
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        case let .screenshot(count):
            Text(count == 1 ? "Screenshot added to Shelf" : "\(count) screenshots added to Shelf")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.bottom, 6)
        case let .timer(message):
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        case let .download(name):
            Text("Downloaded \(name)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        default:
            EmptyView()
        }
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
