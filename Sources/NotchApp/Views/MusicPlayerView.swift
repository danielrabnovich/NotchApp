import SwiftUI

struct MusicPlayerView: View {
    @EnvironmentObject private var media: MediaController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var audio: AudioOutputManager

    private let artSize: CGFloat = 100

    var body: some View {
        let accent = settings.accent(for: media)

        HStack(spacing: 16) {
            artwork(accent: accent)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.hasTrack ? media.title : "Nothing playing")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(media.hasTrack ? media.artist : "Play something in Music, Spotify or a browser")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if media.hasTrack && settings.showVisualizer {
                        AudioVisualizer(color: accent, isPlaying: media.isPlaying, barCount: 5)
                            .frame(width: 22, height: 16)
                            .padding(.top, 3)
                    }
                }
                .id(media.title)
                .transition(.opacity)

                Spacer(minLength: 6)

                ScrubBar(accent: accent)
                    .opacity(media.hasTrack && media.duration > 0 ? 1 : 0.35)
                    .disabled(!media.hasTrack || media.duration <= 0)

                Spacer(minLength: 4)

                controls
            }
            .frame(height: artSize)
        }
        .animation(.easeInOut(duration: 0.25), value: media.title)
    }

    private func artwork(accent: Color) -> some View {
        ZStack(alignment: .bottomTrailing) {
            AlbumArtView(image: media.artwork, size: artSize, cornerRadius: 16)
                .shadow(color: accent.opacity(media.isPlaying ? 0.45 : 0), radius: 14, y: 2)
                .scaleEffect(media.isPlaying || !media.hasTrack ? 1 : 0.92)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: media.isPlaying)

            if let icon = media.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .offset(x: 7, y: 7)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { media.openSourceApp() }
        .help(media.appName.map { "Open \($0)" } ?? "")
    }

    private var controls: some View {
        HStack(spacing: 0) {
            OutputDeviceMenu()
                .frame(width: 30, alignment: .leading)

            Spacer()

            HStack(spacing: 10) {
                Button { media.previousTrack() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 15))
                }
                .buttonStyle(NotchIconButtonStyle(size: 34))

                Button { media.togglePlayPause() } label: {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(NotchIconButtonStyle(size: 40))

                Button { media.nextTrack() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 15))
                }
                .buttonStyle(NotchIconButtonStyle(size: 34))
            }
            .disabled(!media.hasTrack)
            .opacity(media.hasTrack ? 1 : 0.4)

            Spacer()

            Color.clear.frame(width: 30)
        }
    }
}

/// Drag-to-seek progress bar with elapsed / remaining time.
struct ScrubBar: View {
    let accent: Color
    @EnvironmentObject private var media: MediaController
    @State private var dragProgress: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(media.duration, 0.001)
            let progress = dragProgress ?? min(1, media.elapsed(at: context.date) / duration)
            let current = progress * media.duration

            VStack(spacing: 4) {
                GeometryReader { geo in
                    let active = hovering || dragProgress != nil
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule()
                            .fill(accent)
                            .frame(width: max(0, geo.size.width * progress))
                    }
                    .frame(height: active ? 7 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragProgress = min(1, max(0, value.location.x / geo.size.width))
                        }
                        .onEnded { _ in
                            if let p = dragProgress { media.seek(to: p * media.duration) }
                            dragProgress = nil
                        })
                    .onHover { hovering = $0 }
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
                }
                .frame(height: 10)

                HStack {
                    Text(Self.format(current))
                    Spacer()
                    Text("-" + Self.format(max(0, media.duration - current)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    static func format(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct OutputDeviceMenu: View {
    @EnvironmentObject private var audio: AudioOutputManager

    var body: some View {
        Menu {
            ForEach(audio.devices) { device in
                Button {
                    audio.select(device)
                } label: {
                    Label(device.name, systemImage: device.id == audio.currentID ? "checkmark" : device.icon)
                }
            }
        } label: {
            Image(systemName: audio.current?.icon ?? "hifispeaker")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(audio.current.map { "Output: \($0.name)" } ?? "Audio output")
        .onAppear { audio.refresh() }
    }
}
