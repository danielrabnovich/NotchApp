import SwiftUI

/// Search at work: the search bar in miniature, a capsule with a light running round its edge as
/// the bar's own glow does while a search runs. The same colours (or the shimmer's white light, as
/// the bar is set), a soft wash inside following the light, and where it's looking in the middle,
/// in that place's colour once it's known.
struct SearchingCapsule: View {
    var height: CGFloat = 32
    /// Where it's looking ("globe"), or nil for just the light (small, beside a line of text).
    var icon: String? = nil
    var tint: Color? = nil
    /// Laps per second.
    var speed: Double = 0.55

    private var width: CGFloat { (height * 2.25).rounded() }
    private var filled: Bool { height >= 20 }
    private var margin: CGFloat { (height * 0.3).rounded() }

    var body: some View {
        let colored = AppSettings.shared.searchBarEffect == .glow
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: Motion.reduced)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                draw(in: &gc, size: size, t: t, colored: colored)
            }
        }
        // Room round the capsule for the light's bloom, which the canvas would otherwise cut off.
        .padding(-margin)
        .frame(width: width, height: height)
        .overlay {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: height * 0.45, weight: .medium))
                    .foregroundStyle(tint ?? .white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(Motion.small.animation, value: icon)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(in gc: inout GraphicsContext, size: CGSize, t: Double, colored: Bool) {
        let line = max(1.2, height * 0.055)
        let track = CapsuleTrack(rect: CGRect(origin: .zero, size: size).insetBy(dx: margin + line / 2, dy: margin + line / 2))
        let outline = Path(roundedRect: track.rect, cornerRadius: track.rect.height / 2, style: .continuous)

        // The lap eases a little on the long sides and hurries round the ends, like something
        // carried along the edge rather than a dot on a clock.
        let lap = t * speed
        let head = (lap + 0.03 * sin(lap * 4 * .pi)).truncatingRemainder(dividingBy: 1)
        // The tail stretches and shrinks as it goes.
        let tail = 0.38 + 0.08 * sin(t * 2 * .pi * 0.35)
        let color: (Double) -> Color = { p in colored ? SearchGlow.color(at: p + t * 0.08) : .white }

        if filled {
            gc.fill(outline, with: .linearGradient(Gradient(colors: [.white.opacity(0.09), .white.opacity(0.03)]),
                                                   startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            // The light colours the inside where it is, as the bar's wash does.
            gc.drawLayer { wash in
                wash.clip(to: outline)
                wash.addFilter(.blur(radius: height * 0.3))
                let at = track.point(at: head)
                let r = height * 0.55
                wash.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2)),
                          with: .color(color(head).opacity(colored ? 0.32 : 0.12)))
            }
        }
        gc.stroke(outline, with: .color(.white.opacity(filled ? 0.12 : 0.18)), lineWidth: line)

        // The light: a run of short strokes behind the head, fading out. A second, fainter one
        // opposite keeps the bigger capsule from looking lopsided.
        let comets: [(offset: Double, strength: Double)] = filled ? [(0, 1), (0.5, 0.35)] : [(0, 1)]
        let steps = 28
        // Each piece of the light: where it runs, its colour and how strong it is.
        let pieces: [(path: Path, color: Color, fade: Double, head: Bool)] = comets.flatMap { comet in
            (0..<steps).map { k in
                let a = head + comet.offset - tail * Double(k) / Double(steps)
                let b = head + comet.offset - tail * Double(k + 1) / Double(steps)
                var path = Path()
                path.move(to: track.point(at: a))
                path.addLine(to: track.point(at: (a + b) / 2))
                path.addLine(to: track.point(at: b))
                return (path, color(a), pow(1 - Double(k) / Double(steps), 1.8) * comet.strength, k == 0)
            }
        }
        // Its bloom, blurred as one layer. (Blurring each piece on its own left a dark box round
        // the canvas on screen.)
        gc.drawLayer { glow in
            glow.addFilter(.blur(radius: line * 2.2))
            for p in pieces {
                glow.stroke(p.path, with: .color(p.color.opacity(0.7 * p.fade)), style: StrokeStyle(lineWidth: line * 3, lineCap: .round))
            }
        }
        for p in pieces {
            // Butt ends: round ones overlap where the pieces meet and the tail reads as dots.
            gc.stroke(p.path, with: .color(p.color.opacity(0.95 * p.fade)),
                      style: StrokeStyle(lineWidth: line * (0.7 + 0.5 * p.fade), lineCap: p.head ? .round : .butt))
        }
    }
}

/// Points along a capsule's edge by how far round it they are (0–1, clockwise from the top left
/// of the straight top), evenly, so the light keeps one pace on the sides and round the ends.
private struct CapsuleTrack {
    let rect: CGRect

    func point(at position: Double) -> CGPoint {
        let r = rect.height / 2
        let straight = rect.width - rect.height
        let perimeter = 2 * straight + 2 * .pi * r
        var d = (position - floor(position)) * perimeter
        if d < straight { return CGPoint(x: rect.minX + r + d, y: rect.minY) }
        d -= straight
        if d < .pi * r { return arc(CGPoint(x: rect.maxX - r, y: rect.midY), r, -.pi / 2 + d / r) }
        d -= .pi * r
        if d < straight { return CGPoint(x: rect.maxX - r - d, y: rect.maxY) }
        d -= straight
        return arc(CGPoint(x: rect.minX + r, y: rect.midY), r, .pi / 2 + d / r)
    }

    private func arc(_ c: CGPoint, _ r: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
    }
}

/// The search bar's icon while a search runs: the magnifying glass looking around, in a small
/// figure of eight, with the glow's colours flowing through it.
struct ScanningLens: View {
    var size: CGFloat = 17

    var body: some View {
        let colored = AppSettings.shared.searchBarEffect == .glow
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: Motion.reduced)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let p = t * 2 * .pi * 0.6
            let turn = t * 2 * .pi * 0.25
            Image(systemName: "magnifyingglass")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(colored
                    ? AnyShapeStyle(LinearGradient(colors: (0..<4).map { SearchGlow.color(at: Double($0) / 4 + t * 0.1) },
                                                   startPoint: UnitPoint(x: 0.5 + 0.5 * cos(turn), y: 0.5 + 0.5 * sin(turn)),
                                                   endPoint: UnitPoint(x: 0.5 - 0.5 * cos(turn), y: 0.5 - 0.5 * sin(turn))))
                    : AnyShapeStyle(.white.opacity(0.7 + 0.2 * sin(p))))
                .rotationEffect(.degrees(7 * sin(p)))
                .offset(x: size * 0.13 * sin(p), y: size * 0.09 * sin(2 * p))
        }
        .allowsHitTesting(false)
    }
}
