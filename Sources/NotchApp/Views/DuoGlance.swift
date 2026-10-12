import CoreAudio
import SwiftUI

/// The Duo Glance: battery, network and volume in one small glyph, after DuoBar by Mike Li
/// (github.com/Mikeli7666/DuoBar, MIT), which brought the iPhone's three-in-one status glyph to
/// the Mac. Its proportions follow DuoBar's: a ring open at the bottom (120°), the connection in
/// the middle and four volume dots in the gap.
///
/// - Ring: battery charge (green on power, yellow in Low Power Mode, red when low), or how busy
///   the processor is on a Mac without a battery.
/// - Middle: Wi-Fi with its signal, Ethernet, or offline. For a moment after headphones take
///   over the sound, them instead.
/// - Dots: the output volume in quarters; none lit when muted.
struct DuoGlyph: View {
    /// The ring's outer size; everything else scales from it.
    var diameter: CGFloat = 22
    @ObservedObject private var battery = BatteryMonitor.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @ObservedObject private var audio = AudioOutputManager.shared
    @ObservedObject private var stats = SystemMonitor.shared
    /// Scroll on it to change the volume (off for the copy in a peek).
    var scrollable = true
    /// Headphones that just took over the sound, shown in the middle for a moment.
    @State private var arrived: String?
    /// Plugging in: the ring sweeps up from empty to the charge, once.
    @State private var sweep: Double?
    @State private var arrivedTask: Task<Void, Never>?

    private static let gap = 120.0
    private static let sweep = (360 - gap) / 360

    var body: some View {
        let d = diameter
        let stroke = max(1.6, d * 0.08)
        ZStack {
            // The track, faint, so a low battery still reads as part of a ring.
            ring(to: 1).stroke(ringColor.opacity(onPower ? 0.28 : 0.16), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            ring(to: sweep ?? progress).stroke(ringColor, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .animation(.easeInOut(duration: 0.5), value: progress)
            if battery.hasBattery, onPower {
                // A bolt over the top of the ring, cut out of it with a black edge.
                ZStack {
                    Image(systemName: "bolt.fill").font(.system(size: d * 0.36, weight: .black)).foregroundStyle(.black)
                    Image(systemName: "bolt.fill").font(.system(size: d * 0.3, weight: .bold)).foregroundStyle(ringColor)
                }
                .offset(y: -(d - stroke) / 2)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            middle
                .frame(width: d * 0.62, height: d * 0.5)
                .offset(y: -d * 0.06)
            dots(d)
        }
        .frame(width: d, height: d)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: onPower)
        .overlay { if scrollable { ScrollCatcher(onScroll: Self.scrollVolume) } }
        .onChange(of: onPower) { _, plugged in
            guard plugged, battery.hasBattery else { return }
            sweep = 0
            withAnimation(.easeOut(duration: 1.1).delay(0.1)) { sweep = progress }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { sweep = nil }
        }
        .onChange(of: audio.currentID) { _, _ in headphonesArrived() }
        .onDisappear { arrivedTask?.cancel() }
    }

    /// The ring from its start (bottom left) clockwise over the top, `fraction` of the way round.
    private func ring(to fraction: Double) -> some Shape {
        Circle()
            .inset(by: max(1.6, diameter * 0.08) / 2)
            .trim(from: 0, to: Self.sweep * min(max(fraction, 0), 1))
            .rotation(.degrees(90 + Self.gap / 2))
    }

    // MARK: - The ring

    private var onPower: Bool { battery.isCharging || battery.isPluggedIn }

    private var progress: Double {
        if battery.hasBattery { return Double(battery.level) / 100 }
        return stats.snapshot.cpuTotal
    }

    private var ringColor: Color {
        if battery.hasBattery {
            if battery.lowPowerMode { return Color(red: 1, green: 0.84, blue: 0.04) }
            if onPower { return Color(red: 0.2, green: 0.84, blue: 0.35) }
            if battery.level <= 20 { return Color(red: 1, green: 0.27, blue: 0.23) }
            return .white.opacity(0.92)
        }
        let load = stats.snapshot.cpuTotal
        return load > 0.85 ? Color(red: 1, green: 0.38, blue: 0.35) : load > 0.6 ? Color(red: 1, green: 0.7, blue: 0.3) : .white.opacity(0.92)
    }

    // MARK: - The middle

    @ViewBuilder private var middle: some View {
        Group {
            if let arrived {
                Image(systemName: arrived)
                    .font(.system(size: diameter * 0.4, weight: .semibold))
                    .foregroundStyle(Color(red: 0.25, green: 0.6, blue: 1))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                connection
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: arrived)
    }

    @ViewBuilder private var connection: some View {
        let info = network.info
        let size = diameter * 0.42
        switch info.kind {
        case .wifi, .vpn where info.rssi != nil:
            Image(systemName: "wifi", variableValue: info.signalQuality.map(Self.bars) ?? 1)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
        case .ethernet:
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: size * 0.95, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        case .cellular:
            Image(systemName: "personalhotspot")
                .font(.system(size: size * 0.9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        case .vpn, .other:
            Image(systemName: "network")
                .font(.system(size: size * 0.9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        case .offline:
            Image(systemName: "wifi.slash")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    /// Signal in the Wi-Fi glyph's three steps, as the menu bar draws it.
    private static func bars(_ quality: Double) -> Double {
        quality > 0.55 ? 1 : quality > 0.25 ? 0.66 : 0.33
    }

    /// AirPods, Beats or other Bluetooth headphones becoming the output: their glyph for a moment.
    /// Going back to the speakers isn't news.
    private func headphonesArrived() {
        guard let device = audio.current,
              device.transport == kAudioDeviceTransportTypeBluetooth || device.transport == kAudioDeviceTransportTypeBluetoothLE else { return }
        arrivedTask?.cancel()
        arrived = device.icon
        arrivedTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            arrived = nil
        }
    }

    // MARK: - Volume

    /// A trackpad's fine deltas or a wheel's notches, up to raise the volume.
    private static func scrollVolume(_ delta: CGFloat, precise: Bool) {
        guard AudioOutputManager.canSetVolume else { return }
        HUDController.quietUntil = Date().addingTimeInterval(0.8)
        let step = Float(delta) * (precise ? 0.004 : 0.04)
        let v = min(1, max(0, AudioOutputManager.volume + step))
        AudioOutputManager.volume = v
        AudioOutputManager.isMuted = v <= 0.001
        if Int(v * 16) != Int((v - step) * 16) { Haptics.level() }
    }

    /// Four dots on a shallow curve under the middle, as on DuoBar (its offsets, per 230 of ring).
    private func dots(_ d: CGFloat) -> some View {
        let xs: [CGFloat] = [-55.25, -19.5, 19.5, 55.25]
        let ys: [CGFloat] = [-6.5, 6.5, 6.5, -6.5]
        let lit = litDots
        return ZStack {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(i < lit ? 0.92 : 0.28))
                    .frame(width: max(2, d * 0.1), height: max(2, d * 0.1))
                    .offset(x: d * xs[i] / 230, y: d * 0.3 + d * ys[i] / 230)
            }
        }
        .animation(.easeOut(duration: 0.15), value: lit)
    }

    private var litDots: Int {
        let v = audio.level
        guard !audio.muted, v > 0.005 else { return 0 }
        return min(4, max(1, Int((v * 4).rounded(.up))))
    }
}

extension DuoGlyph {
    /// What the Glance's tooltip says: "Wi-Fi “Home” · 82% · Volume 40%".
    @MainActor static var summary: String {
        let info = NetworkMonitor.shared.info, battery = BatteryMonitor.shared, audio = AudioOutputManager.shared
        let net: String = switch info.kind {
        case .wifi: info.ssid.map { "Wi-Fi “\($0)”" } ?? "Wi-Fi"
        case .vpn where info.rssi != nil: (info.ssid.map { "Wi-Fi “\($0)”" } ?? "Wi-Fi") + " · VPN"
        case .offline: "Offline"
        default: info.interfaceName.isEmpty ? "Connected" : info.interfaceName
        }
        let ring = battery.hasBattery ? "Battery \(battery.level)%\(battery.isCharging ? ", charging" : "")"
                                      : "CPU \(Int((SystemMonitor.shared.snapshot.cpuTotal * 100).rounded()))%"
        let volume = audio.muted ? "Muted" : "Volume \(Int((audio.level * 100).rounded()))%"
        return [net, ring, volume + (audio.current.map { " on \($0.name)" } ?? "")].joined(separator: " · ")
    }
}

/// Catches scrolling over a view and nothing else: clicks and hovers fall through to SwiftUI.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(onScroll: onScroll) }
    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: (CGFloat, Bool) -> Void
        init(onScroll: @escaping (CGFloat, Bool) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        // Only a scroll lands here; anything else goes to what's underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) {
            // Natural scrolling flips the deltas; fingers up on the trackpad, or the wheel turned up,
            // still means louder.
            let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            guard dy != 0 else { return }
            onScroll(dy, event.hasPreciseScrollingDeltas)
        }
    }
}
