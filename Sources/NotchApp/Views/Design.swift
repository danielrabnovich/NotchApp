import SwiftUI

/// A level, as macOS draws one now: a thin track that thickens under the pointer, filled to the
/// value. Click anywhere on it or drag.
struct LevelSlider: View {
    let value: Float
    var tint: Color = .white
    var dimmed = false
    let onChange: (Float) -> Void
    var onEnd: () -> Void = {}

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let active = hovering || dragging
            let height: CGFloat = active ? 8 : 5
            let level = CGFloat(min(1, max(0, value)))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(active ? 0.2 : 0.16))
                Capsule()
                    .fill(tint.opacity(dimmed ? 0.4 : 0.95))
                    .frame(width: max(height, geo.size.width * level))
            }
            .frame(height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    onChange(Float(min(1, max(0, g.location.x / max(geo.size.width, 1)))))
                }
                .onEnded { _ in
                    dragging = false
                    onEnd()
                })
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
        }
        .frame(height: 16)
    }
}

/// A list row, as the calendar draws one: something to lead with, a bold title over a gray
/// detail, and a value or a control at the end.
struct NotchRow<Leading: View, Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            trailing
        }
    }
}

/// A clickable row: a soft highlight under the pointer, reaching a little past the row's content
/// as a sidebar's does, so the content keeps its line with the rest of the tab.
struct NotchRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.1 : hovering ? 0.06 : 0))
                    .padding(.horizontal, -7)
                    .padding(.vertical, -4))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// A symbol on a small colored square, as System Settings marks its panes.
struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint.gradient))
    }
}

/// A section's name over its content: small, gray, with its symbol.
struct NotchSectionLabel: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = .white.opacity(0.5)

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .lineLimit(1)
    }
}

/// The thin rule between a tab's sections, standing in for the boxes they used to sit in.
struct SectionDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
    }
}
