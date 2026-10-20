import SwiftUI

/// Sound tab: system volume and output device, plus a fader for each app that's playing.
struct MixerView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var mixer: AudioMixer
    @EnvironmentObject private var audio: AudioOutputManager

    @State private var master: Float = AudioOutputManager.volume
    @State private var draggingMaster = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.notchHeaderRow()
            HStack(alignment: .top, spacing: 18) {
                output.frame(width: 210)
                SectionDivider()
                apps
            }
        }
        .onAppear {
            mixer.viewerAppeared()
            master = AudioOutputManager.volume
        }
        .onDisappear { mixer.viewerDisappeared() }
        .onReceive(poll) { _ in
            if !draggingMaster { master = AudioOutputManager.volume }
        }
    }

    /// Where the sound goes (click to pick another output) and how loud.
    private var output: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                OutputDeviceItems()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: audio.current?.icon ?? "hifispeaker.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(audio.current?.name ?? "Output")
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text("Output")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(NotchRowButtonStyle())
            .menuIndicator(.hidden)
            .help("Pick where sound plays")
            .onAppear { audio.refresh() }

            LevelRow(icon: volumeIcon, value: master, muted: AudioOutputManager.isMuted) { v in
                draggingMaster = true
                master = v
                AudioOutputManager.volume = v
            } onEnd: {
                draggingMaster = false
            } onIconTap: {
                AudioOutputManager.isMuted.toggle()
            }
        }
    }

    private var volumeIcon: String {
        AudioOutputManager.isMuted || master <= 0.001 ? "speaker.slash.fill" : master < 0.34 ? "speaker.wave.1.fill"
            : master < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    /// Each app that's playing, a row apiece, two to a line.
    @ViewBuilder private var apps: some View {
        if mixer.apps.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 18, weight: .medium))
                Text("Apps playing sound show up here")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    ForEach(mixer.apps) { app in
                        AppLevel(app: app)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .animation(Motion.small.animation, value: mixer.apps.map(\.id))
            }
            .scrollEdgeFade()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sound")
                .font(.system(size: 13, weight: .semibold))
            if mixer.permission != .granted {
                Button {
                    if mixer.permission == .denied { AudioCapturePermission.openSettings() } else { mixer.requestPermission() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                        Text(mixer.permission == .denied ? "Allow audio access in Settings to change app volumes"
                                                         : "Allow audio access to change app volumes")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.3))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(Color(red: 1, green: 0.8, blue: 0.3).opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !mixer.volumes.isEmpty || !mixer.muted.isEmpty {
                Button("Reset") { mixer.resetAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(height: 22)
    }

}

/// One app: its icon (click to mute), its name and level, and a slider.
private struct AppLevel: View {
    let app: MixerApp
    @EnvironmentObject private var mixer: AudioMixer

    var body: some View {
        let muted = mixer.isMuted(app)
        let value = mixer.volume(for: app)
        HStack(spacing: 10) {
            Button { mixer.toggleMute(app) } label: {
                AppIcon(bundlePath: app.bundlePath, size: 26)
                    .overlay(alignment: .bottomTrailing) { if muted { MuteBadge() } }
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute" : "Mute")
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(app.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(muted ? "Muted" : "\(Int((value * 100).rounded()))%")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
                LevelSlider(value: muted ? 0 : value) { mixer.setVolume($0, for: app) }
            }
        }
        .opacity(app.isPlaying ? 1 : 0.5)
    }
}

/// A level with its symbol before it (click to mute) and the percentage after.
struct LevelRow: View {
    let icon: String
    let value: Float
    let muted: Bool
    let onChange: (Float) -> Void
    var onEnd: () -> Void = {}
    /// Muting, where the level has it: the symbol becomes the button.
    var onIconTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            let symbol = Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(muted ? 0.4 : 0.85))
                .frame(width: 30)
                .contentTransition(.symbolEffect(.replace))
            if let onIconTap {
                Button(action: onIconTap) { symbol }
                    .buttonStyle(.plain)
                    .help(muted ? "Unmute" : "Mute")
            } else {
                symbol
            }
            LevelSlider(value: muted ? 0 : value, onChange: onChange, onEnd: onEnd)
            Text(muted ? "Muted" : "\(Int((value * 100).rounded()))%")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 34, alignment: .trailing)
        }
    }
}

private struct MuteBadge: View {
    var body: some View {
        Image(systemName: "speaker.slash.fill")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .padding(2.5)
            .background(Circle().fill(.red))
            .offset(x: 3, y: 3)
    }
}
