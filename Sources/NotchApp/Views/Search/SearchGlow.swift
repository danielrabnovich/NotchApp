import SwiftUI

/// An Apple Intelligence–style glow around the search bar: layered strokes of a conic gradient in
/// Apple Intelligence's palette (a crisp core, a soft bloom and a faint wash that tints the bar's
/// inside), each turning at its own pace so the colours flow into one another. It eases in as it comes
/// on, flares as a search starts, pulses with each key typed, runs faster while a search does, and
/// drifts slowly when the bar isn't focused. It's never frozen while it can be seen, except for Reduce Motion. As a shimmer,
/// the same layers carry a white light round the edge instead, with no colour.
struct RainbowGlow: View {
    var style: AppSettings.SearchBarEffect = .glow
    let focused: Bool
    let running: Bool
    /// The bar spans the page above results: keep the glow tight to the bar (edge, inner tint and a
    /// small bloom) so it isn't clipped by the page or spill onto the list below.
    var compact = false
    /// Changes with each key typed, for a pulse of light.
    var typing = 0
    /// Paused while pages slide, another tab is showing or the notch is still springing open.
    @ObservedObject var pager: PagerState
    var onScreen = true

    /// How far the glow spreads past the bar on each side.
    static let spread: CGFloat = 56

    var body: some View {
        let still = pager.isSwiping || pager.isSettling || !onScreen
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // How fast it flows: drifting when the bar isn't focused, faster while a search runs; held
        // where it is while paused (it carries on from the same angle).
        let speed: Float = still || reduceMotion ? 0 : running ? 2.2 : focused ? 1 : 0.35
        let level: Float = running ? 0.8 : focused ? 0.62 : 0.3
        GlowLayers(style: style, speed: speed, level: level, compact: compact, typing: typing)
            .padding(-Self.spread)
            .allowsHitTesting(false)
    }
}

/// The glow as Core Animation layers, seen through the bar's outline in three blurred strata. Every
/// motion is a Core Animation animation that runs in the window server: nothing is drawn per frame by
/// the app. Each speed change restarts the turns from where they are (there's no shared clock to
/// re-base, which could leave a reused glow stuck).
/// Lets the app build the search bar's glow ahead of the first open.
enum SearchGlow {
    @MainActor static func prewarm() { GlowLayers.prewarm() }

    /// Apple Intelligence's palette: lilac/violet, periwinkle, sky, pink, coral and peach, back to
    /// lilac. The glow and everything that says Search is working use these.
    static let palette: [(red: Double, green: Double, blue: Double)] =
        [0xBC82F3, 0x8D9FFF, 0x79C4FB, 0xF5B9EA, 0xFF6778, 0xFFBA71, 0xFFA1F3, 0xBC82F3].map { (hex: Int) in
            let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
            return (r / 255, g / 255, b / 255)
        }

    /// The palette's colour at `position` round it (0–1, wrapping), blended between its stops.
    static func color(at position: Double) -> Color {
        let stops = palette.count - 1 // the last repeats the first
        let scaled = (position - floor(position)) * Double(stops)
        let i = min(Int(scaled), stops - 1), f = scaled - Double(i)
        let a = palette[i], b = palette[i + 1]
        return Color(red: a.red + (b.red - a.red) * f, green: a.green + (b.green - a.green) * f, blue: a.blue + (b.blue - a.blue) * f)
    }
}

private struct GlowLayers: NSViewRepresentable {
    let style: AppSettings.SearchBarEffect
    let speed: Float
    let level: Float
    let compact: Bool
    let typing: Int

    /// Finished glows, kept for the next open: building the layers and their blur filters cost a
    /// dropped frame at the start of every open. (One per notch screen at most, so it stays tiny.)
    @MainActor private static var pool: [GlowView] = []

    func makeNSView(context: Context) -> GlowView {
        let view = Self.pool.popLast() ?? GlowView()
        view.typing = typing
        return view
    }

    func updateNSView(_ view: GlowView, context: Context) {
        view.apply(style)
        view.set(speed: speed, level: level, compact: compact)
        if typing != view.typing {
            if typing > view.typing { view.pulse() }
            view.typing = typing
        }
    }

    static func dismantleNSView(_ view: GlowView, coordinator: ()) {
        view.reset()
        if pool.count < 2 { pool.append(view) }
    }

    /// Builds one ahead of time, so even the first open finds one ready.
    @MainActor static func prewarm() {
        if pool.isEmpty { pool.append(GlowView()) }
    }

    final class GlowView: NSView {
        private struct Stratum {
            let wrapper: CALayer
            let mask: CAShapeLayer
            let gradient: CAGradientLayer
            let line: CGFloat
            let opacity: Float
            /// Seconds per turn at speed 1, and which way.
            var period: Double
            var direction: Double
        }

        /// All the strata; its opacity is how bright the glow is.
        private let glow = CALayer()
        private var strata: [Stratum] = []
        private var speed: Float = 0
        private var level: Float = 0
        private var compact = false
        private var style: AppSettings.SearchBarEffect = .glow
        var typing = 0

        /// One white light with a tail, once round: the shimmer.
        private static let shimmer: [CGColor] = [0, 0, 0.5, 0.95, 0].map { CGColor(gray: 1, alpha: $0) }

        private static let colors: [CGColor] = SearchGlow.palette.map {
            CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerUsesCoreImageFilters = true
            glow.opacity = 0
            layer?.addSublayer(glow)
            // (line width, blur, opacity, seconds per turn, direction), widest first. The wash turns
            // the other way, so the colours inside and along the edge drift through each other.
            let specs: [(CGFloat, Double, Float, Double, Double)] = [(16, 18, 0.2, 15, 1), (5, 6, 0.55, 9, -1), (1.5, 0, 0.95, 6.5, -1)]
            for (i, (line, blur, opacity, period, direction)) in specs.enumerated() {
                let wrapper = CALayer()
                wrapper.opacity = opacity
                if blur > 0, let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]) {
                    wrapper.filters = [filter]
                }
                let masked = CALayer()
                let mask = CAShapeLayer()
                mask.fillColor = nil
                mask.strokeColor = CGColor.white
                mask.lineWidth = line
                masked.mask = mask
                let gradient = CAGradientLayer()
                gradient.type = .conic
                gradient.colors = Self.colors
                gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
                gradient.endPoint = CGPoint(x: 0.5, y: 0)
                // Each starts a third of a turn on from the last, so they never line up.
                gradient.setValue(Double(i) * 2 * .pi / 3, forKeyPath: "transform.rotation.z")
                masked.addSublayer(gradient)
                wrapper.addSublayer(masked)
                glow.addSublayer(wrapper)
                strata.append(Stratum(wrapper: wrapper, mask: mask, gradient: gradient, line: line, opacity: opacity, period: period, direction: direction))
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Colour or shimmer. The shimmer's layers turn together, so the soft light stays with the
        /// bright one, and there's no wash: only the edge lights up.
        func apply(_ style: AppSettings.SearchBarEffect) {
            guard style != self.style else { return }
            self.style = style
            let shimmer = style == .shimmer
            let glow: [(period: Double, direction: Double)] = [(15, 1), (9, -1), (6.5, -1)]
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for i in strata.indices {
                strata[i].gradient.colors = shimmer ? Self.shimmer : Self.colors
                strata[i].wrapper.opacity = shimmer ? [0, 0.4, 1][i] : strata[i].opacity
                strata[i].period = shimmer ? 4 : glow[i].period
                strata[i].direction = shimmer ? 1 : glow[i].direction
                strata[i].gradient.setValue(shimmer ? 0 : Double(i) * 2 * .pi / 3, forKeyPath: "transform.rotation.z")
            }
            CATransaction.commit()
            if speed > 0 { turn() }
            if shimmer { strata[0].wrapper.removeAnimation(forKey: "breathe") } else { breathe(speed > 0) }
        }

        func set(speed: Float, level: Float, compact: Bool) {
            if compact != self.compact {
                self.compact = compact
                needsLayout = true
            }
            let (wasSpeed, wasLevel) = (self.speed, self.level)
            self.speed = speed
            self.level = level
            if level != wasLevel { fade(to: level) }
            if speed != wasSpeed {
                turn()
                breathe(speed > 0)
            }
            // A search starting while it's already flowing: it flares, and settles. (Not as it comes
            // on: that waits for the notch to settle, so a flare there came late, as a jump.)
            if speed > 0, wasSpeed > 0, wasLevel >= 0.5, level > wasLevel + 0.1 {
                ignite()
            }
        }

        /// Ready to be shown again from nothing: dark, still, and with nothing left running.
        func reset() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.removeAllAnimations()
            glow.opacity = 0
            for s in strata {
                hold(s.gradient)
                s.gradient.removeAnimation(forKey: "ignite")
                s.mask.removeAllAnimations()
                s.wrapper.removeAllAnimations()
            }
            CATransaction.commit()
            speed = 0
            level = 0
        }

        /// A key typed: a quick swell of light along the edge.
        func pulse() {
            guard speed > 0 else { return }
            for s in strata.dropFirst() {
                let swell = CABasicAnimation(keyPath: "opacity")
                swell.isAdditive = true
                swell.fromValue = 0.12
                swell.toValue = 0
                swell.duration = 0.35
                swell.timingFunction = CAMediaTimingFunction(name: .easeOut)
                s.wrapper.add(swell, forKey: "pulse")
                let widen = CABasicAnimation(keyPath: "lineWidth")
                widen.isAdditive = true
                widen.fromValue = s.line * 0.3
                widen.toValue = 0
                widen.duration = 0.35
                widen.timingFunction = CAMediaTimingFunction(name: .easeOut)
                s.mask.add(widen, forKey: "pulse")
            }
        }

        /// Brightness eases to the new level from wherever it is now.
        private func fade(to level: Float) {
            let from = glow.presentation()?.opacity ?? glow.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.opacity = level
            CATransaction.commit()
            let ease = CABasicAnimation(keyPath: "opacity")
            ease.fromValue = from
            ease.toValue = level
            ease.duration = 0.35
            ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glow.add(ease, forKey: "level")
        }

        /// Turns every stratum at the current speed, from the angle it's at now.
        private func turn() {
            for s in strata {
                let angle = hold(s.gradient)
                guard speed > 0 else { continue }
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = angle
                turn.toValue = angle + s.direction * 2 * .pi
                turn.duration = s.period / Double(speed)
                turn.repeatCount = .infinity
                s.gradient.add(turn, forKey: "turn")
            }
        }

        /// Stops a gradient's turn where it is on screen, and returns that angle.
        @discardableResult private func hold(_ gradient: CAGradientLayer) -> Double {
            let angle = (gradient.presentation() ?? gradient).value(forKeyPath: "transform.rotation.z") as? Double ?? 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.removeAnimation(forKey: "turn")
            gradient.setValue(angle, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
            return angle
        }

        /// The bloom and wash breathe slowly, out of step with each other.
        private func breathe(_ on: Bool) {
            for (i, s) in strata.dropLast().enumerated() {
                // (The shimmer has no wash to breathe: it would show as a faint ring.)
                guard on, !(style == .shimmer && i == 0) else { s.wrapper.removeAnimation(forKey: "breathe"); continue }
                guard s.wrapper.animation(forKey: "breathe") == nil else { continue }
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.isAdditive = true
                breathe.fromValue = -0.04
                breathe.toValue = 0.05
                breathe.duration = 2.4 + Double(i) * 0.9
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                s.wrapper.add(breathe, forKey: "breathe")
            }
        }

        /// A search starting: a soft flare, a little brighter and wider for a moment, the colours
        /// sweeping round a little faster, then easing into the steady flow.
        private func ignite() {
            let duration = 0.7
            let flare = CAKeyframeAnimation(keyPath: "opacity")
            flare.values = [glow.presentation()?.opacity ?? 0, min(1, level + 0.08), level]
            flare.keyTimes = [0, 0.3, 1]
            flare.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            flare.duration = duration
            glow.add(flare, forKey: "level")
            for s in strata {
                let sweep = CABasicAnimation(keyPath: "transform.rotation.z")
                sweep.isAdditive = true
                sweep.fromValue = -s.direction * 0.25 * .pi
                sweep.toValue = 0
                sweep.duration = duration
                sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                s.gradient.add(sweep, forKey: "ignite")
                let bloom = CABasicAnimation(keyPath: "lineWidth")
                bloom.isAdditive = true
                bloom.fromValue = s.line * 0.25
                bloom.toValue = 0
                bloom.duration = duration
                bloom.timingFunction = CAMediaTimingFunction(name: .easeOut)
                s.mask.add(bloom, forKey: "ignite")
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.frame = bounds
            let bar = bounds.insetBy(dx: RainbowGlow.spread, dy: RainbowGlow.spread)
            let path = CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil)
            // Large enough that the turning gradient always covers the bar.
            let side = hypot(bar.width, bar.height) + 40
            for s in strata {
                s.wrapper.frame = bounds
                s.wrapper.sublayers?.first?.frame = bounds
                s.mask.frame = bounds
                s.mask.path = path
                s.gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                s.gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            CATransaction.commit()
        }
    }
}

/// A highlight that travels around the search bar's edge while a search runs.
private struct SweepingEdge: View {
    @State private var angle = 0.0

    var body: some View {
        Capsule()
            .strokeBorder(AngularGradient(colors: [.clear, .clear, .white.opacity(0.55), .white.opacity(0.9), .clear],
                                          center: .center, angle: .degrees(angle)), lineWidth: 1.2)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { angle = 360 }
            }
            .transition(.opacity)
    }
}

/// Status text that gently pulses while work is happening. The pulse comes from a timeline rather
/// than a repeating animation: one started on appear also caught the layout settling around it
/// and kept replaying that, drawing the text twice.
struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.575 + 0.225 * sin(t * .pi / 0.9)))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: text)
        }
    }
}
