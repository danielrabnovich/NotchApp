import SwiftUI

struct AlbumArtView: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.16)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Bouncing bars that suggest the music's energy, tinted with the accent colour.
/// Bars that move with the music: real levels from AudioSpectrum (bass on the left, treble on the
/// right) when it's listening, or a gentle stand-in animation when it can't (no permission yet).
struct AudioVisualizer: View {
    let color: Color
    let isPlaying: Bool
    var barCount = 4

    @ObservedObject private var spectrum = AudioSpectrum.shared
    @State private var levels: [CGFloat] = [0.4, 0.8, 0.55, 0.7, 0.45, 0.65]
    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let barWidth = (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: max(barWidth, geo.size.height * height(of: i)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onReceive(timer) { _ in
            guard isPlaying, !spectrum.isLive else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                levels = levels.map { _ in CGFloat.random(in: 0.25...1) }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isPlaying)
        .onAppear { AudioSpectrum.shared.viewerAppeared() }
        .onDisappear { AudioSpectrum.shared.viewerDisappeared() }
    }

    private func height(of bar: Int) -> CGFloat {
        guard isPlaying else { return 0.18 }
        guard spectrum.isLive else { return levels[bar % levels.count] }
        // Spread the bars across the bands, bass to treble.
        let bands = spectrum.levels
        let band = min(bands.count - 1, Int((Double(bar) + 0.5) * Double(bands.count) / Double(barCount)))
        return 0.15 + 0.85 * bands[band]
    }
}

/// Thin progress bar used by the volume / brightness HUD.
struct LevelBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                    .animation(.spring(response: 0.25, dampingFraction: 0.85), value: value)
            }
        }
        .frame(height: 5)
    }
}

struct BatteryIcon: View {
    let level: Int
    let charging: Bool
    var animated = false

    @State private var fill: CGFloat = 0

    private var color: Color {
        if charging { return .green }
        if level <= 20 { return .red }
        return .white
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, 18 * fill))
                    .padding(1.5)
            }
            .frame(width: 22, height: 11)
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
        .onAppear {
            let target = CGFloat(level) / 100
            if animated {
                fill = 0
                withAnimation(.easeOut(duration: 1.1).delay(0.15)) { fill = target }
            } else {
                fill = target
            }
        }
        .onChange(of: level) { _, new in
            withAnimation(.easeOut(duration: 0.4)) { fill = CGFloat(new) / 100 }
        }
    }
}

/// The battery as on recent iPhones and iPads: a squat body with the charge as a fill and the
/// number inside it in heavy type, green while charging, yellow in Low Power Mode, red when low,
/// and the bolt beside it while plugged in.
struct BatteryGlyph: View {
    let level: Int
    let charging: Bool
    var pluggedIn = false
    var lowPower = false
    /// Height of the body; everything else scales from it.
    var height: CGFloat = 13.5

    /// Body plus nub, and the bolt when plugged in.
    static func width(height: CGFloat = 13.5, plugged: Bool) -> CGFloat {
        bodyWidth(height) + 1 + nubWidth(height) + (plugged ? boltWidth(height) + 2 : 0)
    }
    private static func bodyWidth(_ h: CGFloat) -> CGFloat { (h * 1.95).rounded() }
    private static func nubWidth(_ h: CGFloat) -> CGFloat { max(1.5, h * 0.11) }
    private static func boltWidth(_ h: CGFloat) -> CGFloat { h * 0.62 }

    /// Critically low and not charging: the whole battery tints red, not just the sliver of fill.
    private var critical: Bool { level <= 10 && !charging && !pluggedIn }

    private var fillColor: Color {
        if charging { return Color(red: 0.2, green: 0.84, blue: 0.35) }
        if lowPower { return Color(red: 1, green: 0.84, blue: 0.04) }
        if level <= 20 { return Color(red: 1, green: 0.27, blue: 0.23) }
        return .white
    }

    private var trackColor: Color {
        critical ? Color(red: 1, green: 0.27, blue: 0.23).opacity(0.45) : .white.opacity(0.35)
    }

    var body: some View {
        let w = Self.bodyWidth(height)
        let shape = RoundedRectangle(cornerRadius: height * 0.34, style: .continuous)
        let fraction = CGFloat(min(max(level, 0), 100)) / 100
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                shape.fill(trackColor)
                Rectangle()
                    .fill(fillColor)
                    .frame(width: w * fraction)
                Text("\(level)")
                    // Heavy and tall, as iOS draws it; "100" a little smaller so it keeps off the ends.
                    .font(.system(size: height * (level >= 100 ? 0.68 : 0.82), weight: .bold))
                    .tracking(level >= 100 ? -0.4 : -0.2)
                    .foregroundStyle(critical ? .white : .black.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: w)
            }
            .frame(width: w, height: height)
            .clipShape(shape)
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 1.5, topTrailingRadius: 1.5, style: .continuous)
                .fill(level >= 99 ? fillColor : trackColor)
                .frame(width: Self.nubWidth(height), height: height * 0.36)
            if pluggedIn || charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: height * 0.7, weight: .bold))
                    .foregroundStyle(charging ? fillColor : .white.opacity(0.85))
                    .frame(width: Self.boltWidth(height))
                    .padding(.leading, 1)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.4), value: level)
        .animation(.easeOut(duration: 0.25), value: fillColor)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: pluggedIn || charging)
        .accessibilityElement()
        .accessibilityLabel("Battery \(level)%\(charging ? ", charging" : "")\(lowPower ? ", Low Power Mode" : "")")
    }
}

/// Circular icon button with a soft hover highlight.
struct NotchIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, size: size)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.22 : hovering ? 0.12 : 0)))
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    /// Lets two-finger horizontal scrolls over this view scroll it instead of switching tabs.
    func horizontalScrollRegion(_ id: String, in viewModel: NotchViewModel, active: Bool = true) -> some View {
        background(GeometryReader { geo in
            let frame = geo.frame(in: .global)
            Color.clear
                .onAppear { viewModel.horizontalScrollRegions[id] = active ? frame : nil }
                .onChange(of: frame) { _, f in viewModel.horizontalScrollRegions[id] = active ? f : nil }
                .onChange(of: active) { _, a in viewModel.horizontalScrollRegions[id] = a ? frame : nil }
                .onDisappear { viewModel.horizontalScrollRegions[id] = nil }
        })
    }
}

/// Title-style switcher between the panes that share a tab ("Tasks · Notes", "Shelf · Downloads").
struct PaneSwitcher<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.35))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }
}

/// An app's Finder icon from its bundle path, or a generic gear for bare processes.
struct AppIcon: View {
    let bundlePath: String?
    var size: CGFloat = 12
    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let bundlePath {
            Image(nsImage: Self.icon(for: bundlePath)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: size * 0.66))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: size, height: size)
        }
    }

    private static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

/// Real system and app icons (AirDrop, Tailscale) rather than look-alike symbols.
@MainActor
enum SystemIcons {
    static let airDrop = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
    static let tailscale: NSImage? = FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
        ? NSWorkspace.shared.icon(forFile: "/Applications/Tailscale.app") : nil
}

extension View {
    /// The shared raised surface: a top-lit fill with a hairline edge that catches the light,
    /// brighter while `active` (focused, hovered).
    func notchSurface<S: InsettableShape>(_ shape: S, active: Bool = false) -> some View {
        background(shape.fill(LinearGradient(colors: [.white.opacity(active ? 0.13 : 0.09), .white.opacity(active ? 0.08 : 0.05)],
                                             startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(active ? 0.26 : 0.14), .white.opacity(active ? 0.09 : 0.04)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

/// A small keyboard key, for shortcut hints ("↩", "⌃⌥G").
struct KeyCap: View {
    let text: String
    var onAccent = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(onAccent ? 0.95 : 0.55))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(.white.opacity(onAccent ? 0.22 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(.white.opacity(onAccent ? 0 : 0.08), lineWidth: 1))
    }
}

/// Rounded text button: solid white when primary, a soft fill otherwise.
struct NotchPillButtonStyle: ButtonStyle {
    var primary = false
    var height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, primary: primary, height: height)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let primary: Bool
        let height: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: primary ? .semibold : .medium))
                .foregroundStyle(primary ? .black : .white.opacity(0.88))
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: height)
                .background(Capsule().fill(primary ? .white.opacity(hovering ? 1 : 0.92) : .white.opacity(hovering ? 0.16 : 0.1)))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}
