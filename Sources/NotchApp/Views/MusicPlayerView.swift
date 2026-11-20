import SwiftUI

struct MusicPlayerView: View {
    @EnvironmentObject private var media: MediaController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var audio: AudioOutputManager
    @ObservedObject private var lyrics = Lyrics.shared

    /// Beside Home's day, in half the notch: the art a little smaller and closer, so the player
    /// fits its half (it ran a few points over, and the art was cut off at the left).
    var half = false
    private var artSize: CGFloat { half ? 90 : 100 }

    var body: some View {
        let accent = settings.accent(for: media)

        HStack(spacing: half ? 14 : 16) {
            artwork(accent: accent)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.hasTrack ? media.title : "Nothing playing")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        // With lyrics on, the line being sung takes the artist's place.
                        if media.hasTrack, case let .synced(lines) = lyrics.state {
                            LyricLine(lines: lines, accent: accent)
                        } else {
                            Text(media.hasTrack ? media.artist : "Play something in Music, Spotify or a browser")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
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
            .frame(height: 100)
        }
        .animation(.easeInOut(duration: 0.25), value: media.title)
    }

    private func artwork(accent: Color) -> some View {
        ZStack(alignment: .bottomTrailing) {
            AlbumArtView(image: media.artwork, size: artSize, cornerRadius: 16)
                .shadow(color: accent.opacity(media.isPlaying ? 0.45 : 0), radius: 14, y: 2)
                .scaleEffect(media.isPlaying || !media.hasTrack ? 1 : 0.92)
                .animation(Motion.pane.animation, value: media.isPlaying)

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

            LyricsButton()
                .frame(width: 30, alignment: .trailing)
        }
    }
}

/// Music when it isn't playing: the paused track and its controls, small, beside Home's day.
/// Centered: the artwork over the song over the controls, all down the middle (unless Home's too
/// short for that, under a call bar).
struct CompactMusicCard: View {
    var centered = false
    @EnvironmentObject private var media: MediaController

    var body: some View {
        if centered {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 8) {
                    art
                    VStack(spacing: 1) {
                        Text(media.title)
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(media.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    controls
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                beside
            }
        } else {
            beside
        }
    }

    /// The artwork beside the song, the controls under both.
    private var beside: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                art
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(media.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            controls
        }
        .frame(maxHeight: .infinity)
    }

    private var art: some View {
        ZStack(alignment: .bottomTrailing) {
            AlbumArtView(image: media.artwork, size: 52, cornerRadius: 10)
            if let icon = media.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: 5, y: 5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { media.openSourceApp() }
        .help(media.appName.map { "Open \($0)" } ?? "")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { media.previousTrack() } label: {
                Image(systemName: "backward.fill").font(.system(size: 12))
            }
            .buttonStyle(NotchIconButtonStyle(size: 28))
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(NotchIconButtonStyle(size: 32))
            .help(media.isPlaying ? "Pause" : "Resume")
            Button { media.nextTrack() } label: {
                Image(systemName: "forward.fill").font(.system(size: 12))
            }
            .buttonStyle(NotchIconButtonStyle(size: 28))
        }
        .frame(maxWidth: .infinity)
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
                    .animation(Motion.small.animation, value: active)
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

/// The sound outputs as menu items: each with its own symbol, the one in use checked.
struct OutputDeviceItems: View {
    @ObservedObject private var audio = AudioOutputManager.shared

    var body: some View {
        ForEach(audio.devices) { device in
            Toggle(isOn: Binding(get: { audio.currentID == device.id }, set: { _ in audio.select(device) })) {
                Label(device.name, systemImage: device.icon)
            }
        }
    }
}

struct OutputDeviceMenu: View {
    @EnvironmentObject private var audio: AudioOutputManager

    var body: some View {
        Menu {
            OutputDeviceItems()
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

/// The music card's lyrics switch, opposite the output menu: the quote marks fill while lyrics are
/// on, and fade when this song has no synced lyrics.
private struct LyricsButton: View {
    @ObservedObject private var lyrics = Lyrics.shared
    @EnvironmentObject private var media: MediaController

    var body: some View {
        let missing = lyrics.state == .none
        Button { lyrics.enabled.toggle() } label: {
            Image(systemName: lyrics.enabled ? "quote.bubble.fill" : "quote.bubble")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(missing ? 0.3 : lyrics.enabled ? 0.9 : 0.7))
                .symbolEffect(.pulse, isActive: lyrics.state == .loading)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!media.hasTrack)
        .help(missing ? "No synced lyrics for this song" : lyrics.enabled ? "Hide lyrics" : "Show lyrics (from LRCLIB)")
    }
}

/// The line being sung, filling with the artwork's colour as the song moves through it, and
/// sliding up to the next. Between lines (an intro, a solo) it shows the next one, dimmed.
struct LyricLine: View {
    let lines: [Lyrics.Line]
    let accent: Color
    @EnvironmentObject private var media: MediaController

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !media.isPlaying)) { context in
            // A little ahead: the eye wants the word as it's sung, not after.
            let time = media.elapsed(at: context.date) + 0.25
            let position = Lyrics.position(in: lines, at: time)
            let line = position.map { lines[$0.index] }
            let waiting = line?.text.isEmpty != false
            let shown = waiting ? lines.first { $0.time > time && !$0.text.isEmpty }?.text ?? "" : line!.text
            let progress = waiting ? 0 : position?.progress ?? 0
            Text(shown.isEmpty ? "♪" : shown)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(waiting ? 0.3 : 0.45))
                .overlay(alignment: .leading) {
                    // The sung part, as a mask over the same text, so the colour runs through it.
                    Text(shown)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(accent)
                        .mask(alignment: .leading) {
                            GeometryReader { geo in Rectangle().frame(width: geo.size.width * progress) }
                        }
                        .opacity(waiting ? 0 : 1)
                }
                .id(shown)
                .transition(.push(from: .bottom).combined(with: .opacity))
                .animation(.easeOut(duration: 0.25), value: shown)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
    }
}
