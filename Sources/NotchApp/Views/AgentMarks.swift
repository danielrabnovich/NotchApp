import SwiftUI

/// Each tool's brand mark, from its published SVG on a 24×24 grid.
/// Claude and OpenCode: Simple Icons. Codex and Z.ai: Lobe Icons.
struct AgentMark: Shape {
    let tool: AgentMonitor.Tool

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let t = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2).scaledBy(x: side / 24, y: side / 24)
        return Path(Self.paths[tool]!).applying(t)
    }

    /// Marks with holes cut by an inner subpath.
    var evenOdd: Bool { tool != .claude }

    private static let paths: [AgentMonitor.Tool: CGPath] = [
        // Claude's starburst.
        .claude: SVGPath.parse("m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"),
        // Codex: OpenAI's cloud with a prompt cut out.
        .codex: SVGPath.parse("M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z"),
        // OpenCode's frame.
        .opencode: SVGPath.parse("M22 24H2V0h20zM17 4.8H7v14.4h10z"),
        // ZCode: the Z.ai mark.
        .zcode: SVGPath.parse("M12.105 2L9.927 4.953H.653L2.83 2h9.276zM23.254 19.048L21.078 22h-9.242l2.174-2.952h9.244zM24 2L9.264 22H0L14.736 2H24z"),
    ]
}

/// SVG path data as a CGPath: every command, arcs turned into curves.
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        var s = Reader(bytes: Array(d.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?, lastCommand: UInt8 = 0
        while let command = s.command(after: lastCommand) {
            let relative = command >= 97 // lowercase
            let base = relative ? current : .zero
            func point() -> CGPoint { CGPoint(x: base.x + s.number(), y: base.y + s.number()) }
            var control: CGPoint?
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                current = point(); start = current
                path.move(to: current)
            case UInt8(ascii: "l"):
                current = point()
                path.addLine(to: current)
            case UInt8(ascii: "h"):
                current.x = base.x + s.number()
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                current.y = base.y + s.number()
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                let c1 = point(), c2 = point()
                current = point(); control = c2
                path.addCurve(to: current, control1: c1, control2: c2)
            case UInt8(ascii: "s"):
                let c1 = reflected(lastControl, about: current, if: "cCsS".utf8.contains(lastCommand))
                let c2 = point()
                current = point(); control = c2
                path.addCurve(to: current, control1: c1, control2: c2)
            case UInt8(ascii: "q"):
                let c = point()
                current = point(); control = c
                path.addQuadCurve(to: current, control: c)
            case UInt8(ascii: "t"):
                let c = reflected(lastControl, about: current, if: "qQtT".utf8.contains(lastCommand))
                current = point(); control = c
                path.addQuadCurve(to: current, control: c)
            case UInt8(ascii: "a"):
                let rx = s.number(), ry = s.number(), angle = s.number()
                let large = s.flag(), sweep = s.flag()
                let end = point()
                addArc(to: path, from: current, to: end, rx: rx, ry: ry, angle: angle, large: large, sweep: sweep)
                current = end
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
            default:
                return path
            }
            lastControl = control
            // A repeated moveto draws lines.
            lastCommand = command | 0x20 == UInt8(ascii: "m") ? (relative ? UInt8(ascii: "l") : UInt8(ascii: "L")) : command
        }
        return path
    }

    private static func reflected(_ control: CGPoint?, about p: CGPoint, if follows: Bool) -> CGPoint {
        guard follows, let c = control else { return p }
        return CGPoint(x: 2 * p.x - c.x, y: 2 * p.y - c.y)
    }

    /// The SVG spec's endpoint-to-center conversion, then a cubic per quarter turn at most.
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                               angle: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = angle * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = sqrt(max(0, num / den))
        if large == sweep { k = -k }
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angleOf(_ ux: CGFloat, _ uy: CGFloat) -> CGFloat { atan2(uy, ux) }
        let theta = angleOf((x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angleOf((-x1 - cx1) / rx, (-y1 - cy1) / ry) - theta
        if sweep, delta < 0 { delta += 2 * .pi }
        if !sweep, delta > 0 { delta -= 2 * .pi }
        let pieces = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(pieces)
        let t = 4 / 3 * tan(step / 4)
        func onEllipse(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi, y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
        }
        func tangent(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi, y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
        }
        var a = theta
        for _ in 0..<pieces {
            let b = a + step
            let from = onEllipse(a), to = onEllipse(b), ta = tangent(a), tb = tangent(b)
            path.addCurve(to: to, control1: CGPoint(x: from.x + t * ta.x, y: from.y + t * ta.y),
                          control2: CGPoint(x: to.x - t * tb.x, y: to.y - t * tb.y))
            a = b
        }
    }

    /// Numbers and flags as SVG packs them: "-.5.5", "1e-3", arc flags run together ("01").
    private struct Reader {
        let bytes: [UInt8]
        var i = 0

        private mutating func skip() {
            while i < bytes.count, [32, 44, 9, 10, 13].contains(bytes[i]) { i += 1 }
        }

        private func isNumberStart(_ b: UInt8) -> Bool { (48...57).contains(b) || b == 45 || b == 43 || b == 46 }

        /// The next command letter, or the previous one again when numbers follow without one.
        mutating func command(after previous: UInt8) -> UInt8? {
            skip()
            guard i < bytes.count else { return nil }
            let b = bytes[i]
            if isNumberStart(b) { return previous == 0 ? nil : previous }
            i += 1
            return b
        }

        mutating func number() -> CGFloat {
            skip()
            let from = i
            if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
            var dot = false
            while i < bytes.count {
                let b = bytes[i]
                if (48...57).contains(b) { i += 1 }
                else if b == 46, !dot { dot = true; i += 1 }
                else if b == 101 || b == 69 { // exponent
                    i += 1
                    if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
                    dot = true
                } else { break }
            }
            return CGFloat(Double(String(decoding: bytes[from..<i], as: UTF8.self)) ?? 0)
        }

        mutating func flag() -> Bool {
            skip()
            guard i < bytes.count else { return false }
            defer { i += 1 }
            return bytes[i] == 49
        }
    }
}
