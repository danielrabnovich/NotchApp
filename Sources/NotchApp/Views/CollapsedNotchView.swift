import SwiftUI

/// Live activities shown on either side of the hardware notch.
struct CollapsedNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var media: MediaController
    @EnvironmentObject private var activity: ActivityCenter
    @EnvironmentObject private var battery: BatteryMonitor
    @EnvironmentObject private var tasks: TaskStore

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
        case .tasks:
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .peek:
            if let peek = activity.peek { peekLeading(peek).transition(.opacity) }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch viewModel.activity {
        case .none:
            Color.clear
        case .tasks:
            TaskCountBadge(count: viewModel.taskBadgeCount ?? 0)
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
        }
    }

    @ViewBuilder private func subtitle(for peek: SneakPeek) -> some View {
        switch peek {
        case let .meeting(title, minutes, _):
            Text("\(title) · in \(minutes) min")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        case let .screenshot(count):
            Text(count == 1 ? "Screenshot added to Shelf" : "\(count) screenshots added to Shelf")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
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
