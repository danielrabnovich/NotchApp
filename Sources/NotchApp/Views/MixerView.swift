import SwiftUI

/// Sound tab: system volume and output device, plus a fader for each app that's playing.
struct MixerView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var mixer: AudioMixer
    @EnvironmentObject private var audio: AudioOutputManager

    @State private var master: Float = AudioOutputManager.volume
    @State private var draggingMaster = false
    @State private var overflows = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .top, spacing: 10) {
                ChannelStrip(name: audio.current?.name ?? "Output", value: master, muted: AudioOutputManager.isMuted,
                             tint: .white) {
                    Image(systemName: audio.current?.icon ?? "hifispeaker.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                } onChange: { v in
                    draggingMaster = true
                    master = v
                    AudioOutputManager.volume = v
                } onEnd: {
                    draggingMaster = false
                } onIconTap: {
                    AudioOutputManager.isMuted.toggle()
                }

                Rectangle().fill(.white.opacity(0.08)).frame(width: 1)

                if mixer.apps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 20, weight: .medium))
                        Text("Apps playing sound show up here")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { outer in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(mixer.apps) { app in
                                    appStrip(app)
                                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                                }
                            }
                            .frame(height: outer.size.height)
                            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: mixer.apps.map(\.id))
                            .background(GeometryReader { inner in
                                Color.clear
                                    .onAppear { overflows = inner.size.width > outer.size.width + 1 }
                                    .onChange(of: inner.size.width > outer.size.width + 1) { _, o in overflows = o }
                            })
                        }
                    }
                    .horizontalScrollRegion("mixer", in: viewModel, active: overflows)
                }
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
            OutputDeviceMenu()
        }
        .frame(height: 22)
    }

    private func appStrip(_ app: MixerApp) -> some View {
        ChannelStrip(name: app.name, value: mixer.volume(for: app), muted: mixer.isMuted(app),
                     tint: .white, dimmed: !app.isPlaying) {
            AppIcon(bundlePath: app.bundlePath, size: 22)
        } onChange: { v in
            mixer.setVolume(v, for: app)
        } onEnd: {
        } onIconTap: {
            mixer.toggleMute(app)
        }
    }
}

/// One mixer channel: level readout, a wide vertical fader, and an icon that toggles mute.
private struct ChannelStrip<Icon: View>: View {
    let name: String
    let value: Float
    let muted: Bool
    let tint: Color
    var dimmed = false
    @ViewBuilder let icon: Icon
    let onChange: (Float) -> Void
    let onEnd: () -> Void
    let onIconTap: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Text(muted ? "Muted" : "\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(muted ? 0.4 : 0.75))
                .frame(height: 12)
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.12 : 0.08))
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(muted ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(tint.opacity(0.88).gradient))
                        .frame(height: max(0, h * CGFloat(value)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in onChange(Float(1 - g.location.y / max(h, 1))) }
                    .onEnded { _ in onEnd() })
                .onHover { hovering = $0 }
            }
            .frame(width: 30)
            Button(action: onIconTap) {
                icon
                    .overlay(alignment: .bottomTrailing) {
                        if muted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Circle().fill(.red))
                                .offset(x: 3, y: 3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute" : "Mute")
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 54)
        }
        .frame(width: 54)
        .opacity(dimmed ? 0.55 : 1)
    }
}
