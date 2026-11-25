import AppKit
import SwiftUI

/// The Stats Rings Glance: how busy the Mac is as three nested rings, like Activity's, in the
/// Stats page's own colors so each reads the same in both places: CPU outside (blue), GPU in
/// the middle (purple), memory inside (green). No warning colors: Stats uses orange and yellow
/// for other things (power, wired memory), and the peek has the numbers.
struct StatRings: View {
    var diameter: CGFloat = 22
    @ObservedObject private var stats = SystemMonitor.shared

    var body: some View {
        let s = stats.snapshot
        // In 2% steps (about a point of a 22 pt ring): a reading that barely moved isn't redrawn.
        let step = { (v: Double) in (v * 50).rounded() / 50 }
        let memory = s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : 0
        // The Glance's proportions at every size (2 pt rings, 1 pt apart at 22 pt), in half points to
        // stay crisp.
        let half = { (v: CGFloat) in max(1, (v * 2).rounded() / 2) }
        RingLayers(values: [step(s.cpuTotal), step(s.gpu ?? 0), step(memory)],
                   colors: [StatsPalette.cpu, StatsPalette.gpu, StatsPalette.memory].map { NSColor($0) },
                   line: half(diameter / 11), gap: half(diameter / 22))
            .frame(width: diameter, height: diameter)
            .pixelSnapped()
    }
}

/// The rings as Core Animation shape layers. A new reading eases each ring's end over 0.6 s in
/// the window server. Animated in SwiftUI, every frame of that ease re-laid out the whole closed
/// notch, and with a reading every 2 s the notch was redrawing at the display's rate a third of
/// the time.
private struct RingLayers: NSViewRepresentable {
    let values: [Double]
    let colors: [NSColor]
    let line: CGFloat
    let gap: CGFloat

    func makeNSView(context: Context) -> RingsView { RingsView() }

    func updateNSView(_ view: RingsView, context: Context) {
        view.update(values: values, colors: colors, line: line, gap: gap)
    }

    final class RingsView: NSView {
        private var tracks: [CAShapeLayer] = []
        private var fills: [CAShapeLayer] = []
        private var values: [Double] = []
        private var line: CGFloat = 2
        private var gap: CGFloat = 1

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            placeRings()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            let scale = window?.backingScaleFactor ?? 2
            (tracks + fills).forEach { $0.contentsScale = scale }
        }

        func update(values: [Double], colors: [NSColor], line: CGFloat, gap: CGFloat) {
            let rebuilt = fills.count != values.count
            if rebuilt {
                (tracks + fills).forEach { $0.removeFromSuperlayer() }
                tracks = values.map { _ in ring() }
                fills = values.map { _ in ring() }
                fills.forEach { $0.lineCap = .round }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, color) in colors.enumerated() where i < fills.count {
                tracks[i].strokeColor = color.withAlphaComponent(0.22).cgColor
                fills[i].strokeColor = color.cgColor
            }
            if rebuilt || line != self.line || gap != self.gap {
                self.line = line
                self.gap = gap
                placeRings()
            }
            CATransaction.commit()

            let ends = values.map { CGFloat(min(max($0, 0.02), 1)) }
            for (fill, end) in zip(fills, ends) where fill.strokeEnd != end {
                if rebuilt || self.values.isEmpty {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    fill.strokeEnd = end
                    CATransaction.commit()
                } else {
                    let ease = CABasicAnimation(keyPath: "strokeEnd")
                    ease.fromValue = fill.presentation()?.strokeEnd ?? fill.strokeEnd
                    ease.toValue = end
                    ease.duration = 0.6
                    ease.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    fill.strokeEnd = end
                    fill.add(ease, forKey: "strokeEnd")
                    CATransaction.commit()
                }
            }
            self.values = values
        }

        private func ring() -> CAShapeLayer {
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.actions = ["path": NSNull(), "lineWidth": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
            self.layer?.addSublayer(layer)
            return layer
        }

        /// Each ring a circle from 12 o'clock clockwise, outermost first, inset by a ring and a gap.
        private func placeRings() {
            let side = min(bounds.width, bounds.height)
            guard side > 0 else { return }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for i in fills.indices {
                let radius = side / 2 - CGFloat(i) * (line + gap) - line / 2
                guard radius > 0 else { continue }
                let path = CGMutablePath()
                // Unflipped (y up): clockwise from the top.
                path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
                for layer in [tracks[i], fills[i]] {
                    layer.frame = bounds
                    layer.path = path
                    layer.lineWidth = line
                }
            }
            CATransaction.commit()
        }
    }
}
