import SwiftUI

/// "Working on it", after the new Siri: a ring of small glowing circles revolving inside a dark
/// glass disc. The lead circle is largest and the rest trail off behind it, the ring breathes a
/// little, and the colors drift around it through Apple Intelligence's palette.
struct ThinkingRing: View {
    var size: CGFloat = 44
    /// Turns per second.
    var speed: Double = 0.65
    /// Draws the dark disc behind the circles (off where something already sits behind it).
    var disc = true

    private static let count = 8
    /// Violet, pink, coral, peach, sky: the same colors as the search bar's glow.
    private static let palette: [(Double, Double, Double)] = [
        (0.74, 0.51, 0.95), (0.96, 0.45, 0.82), (1.00, 0.40, 0.47), (1.00, 0.73, 0.44), (0.47, 0.77, 0.98),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { gc, canvas in
                let bounds = CGRect(origin: .zero, size: canvas)
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                let s = min(canvas.width, canvas.height)
                if disc {
                    gc.fill(Path(ellipseIn: bounds), with: .radialGradient(
                        Gradient(colors: [.white.opacity(0.10), .black.opacity(0.55)]),
                        center: CGPoint(x: center.x, y: center.y - s * 0.2), startRadius: 0, endRadius: s * 0.6))
                    gc.stroke(Path(ellipseIn: bounds.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.14)), lineWidth: 1)
                }

                let dots = Self.dots(t: t * speed, center: center, size: s)
                // A soft glow under the circles, then the circles themselves.
                gc.drawLayer { glow in
                    glow.addFilter(.blur(radius: s * 0.07))
                    glow.blendMode = .plusLighter
                    for dot in dots {
                        let r = dot.radius * 1.9
                        glow.fill(Path(ellipseIn: CGRect(x: dot.point.x - r, y: dot.point.y - r, width: r * 2, height: r * 2)),
                                  with: .color(dot.color.opacity(0.55 * dot.strength)))
                    }
                }
                for dot in dots {
                    let r = dot.radius
                    gc.fill(Path(ellipseIn: CGRect(x: dot.point.x - r, y: dot.point.y - r, width: r * 2, height: r * 2)),
                            with: .color(dot.color.opacity(0.35 + 0.65 * dot.strength)))
                }
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    private struct Dot {
        let point: CGPoint
        let radius: CGFloat
        let color: Color
        /// 1 for the lead circle, fading along the trail.
        let strength: Double
    }

    private static func dots(t: Double, center: CGPoint, size s: CGFloat) -> [Dot] {
        let spin = t * 2 * .pi
        let ring = s * 0.29 * (1 + 0.05 * sin(t * 2 * .pi * 0.8))
        return (0..<count).map { i in
            // i = 0 leads; the others follow behind it around the ring.
            let angle = spin - Double(i) * 2 * .pi / Double(count)
            let strength = pow(1 - Double(i) / Double(count), 1.4)
            let point = CGPoint(x: center.x + cos(angle) * ring, y: center.y + sin(angle) * ring)
            let radius = s * (0.035 + 0.055 * strength)
            return Dot(point: point, radius: radius, color: color(at: Double(i) / Double(count) + t * 0.12), strength: strength)
        }
    }

    /// A color from the palette, blended smoothly around the ring.
    private static func color(at position: Double) -> Color {
        let p = position - floor(position)
        let scaled = p * Double(palette.count)
        let a = palette[Int(scaled) % palette.count], b = palette[(Int(scaled) + 1) % palette.count]
        let f = scaled - floor(scaled)
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }
}
