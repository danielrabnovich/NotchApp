import SwiftUI

/// The notch silhouette: concave flares where it meets the top of the screen,
/// and rounded corners at the bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// How round the bottom corners are: 1/3 is the closed notch's tighter curve, `NotchShape.circle`
    /// a true quarter circle (the open notch, so its outline matches the glass drawn inside it).
    var roundness: CGFloat = 1.0 / 3

    /// A quarter circle as a cubic curve: its control points sit this far along each edge.
    static let circle: CGFloat = 0.4477

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), roundness) }
        set { topRadius = newValue.first.first; bottomRadius = newValue.first.second; roundness = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius
        let b = max(0, min(bottomRadius, r.height - t, (r.width - 2 * t) / 2))
        let k = b * roundness
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY),
                   control1: CGPoint(x: r.minX + t, y: r.maxY - k), control2: CGPoint(x: r.minX + t + k, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b),
                   control1: CGPoint(x: r.maxX - t - k, y: r.maxY), control2: CGPoint(x: r.maxX - t, y: r.maxY - k))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}
