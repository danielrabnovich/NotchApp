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
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
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
struct AudioVisualizer: View {
    let color: Color
    let isPlaying: Bool
    var barCount = 4

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
                        .frame(width: barWidth, height: max(barWidth, geo.size.height * (isPlaying ? levels[i % levels.count] : 0.18)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onReceive(timer) { _ in
            guard isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                levels = levels.map { _ in CGFloat.random(in: 0.25...1) }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isPlaying)
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
