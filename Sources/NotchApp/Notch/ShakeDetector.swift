import Foundation

/// Tells a shake of the pointer from ordinary dragging: quick left-right swings, at least three
/// turns within `window` seconds, each swing at least `swing` points long, and mostly sideways.
/// A pure function of the points, so synthetic sequences can check it (`debug shaketest`).
struct ShakeDetector {
    struct Point {
        let t: TimeInterval
        let x: Double
        let y: Double
    }

    /// The turns that make a shake, and the time they must fit in.
    static let turns = 3
    static let window: TimeInterval = 0.6
    /// How far the pointer must swing back past its furthest point for it to count as a turn.
    /// Correcting an overshoot, or the jitter of aiming at a target, stays well under it.
    static let swing: Double = 40
    /// Up-and-down travel allowed for each point of sideways travel (a circle has as much of one as the other).
    static let drift: Double = 0.6

    /// Whether the points (oldest first) end in a shake.
    static func isShake(_ points: [Point]) -> Bool {
        guard let last = points.last else { return false }
        let recent = points.filter { last.t - $0.t <= window }
        guard recent.count > 3 else { return false }

        let anchor = recent[0].x
        var extreme = anchor
        var direction: Double = 0
        var turnTimes: [TimeInterval] = []
        for p in recent.dropFirst() {
            if direction == 0 {
                // The first swing: under way once it's gone far enough one way.
                guard abs(p.x - anchor) >= swing else { continue }
                direction = p.x > anchor ? 1 : -1
                extreme = p.x
            } else if (p.x - extreme) * direction > 0 {
                extreme = p.x
            } else if abs(p.x - extreme) >= swing {
                turnTimes.append(p.t)
                direction = -direction
                extreme = p.x
            }
        }
        guard turnTimes.count >= turns else { return false }

        var dx = 0.0, dy = 0.0
        for (a, b) in zip(recent, recent.dropFirst()) {
            dx += abs(b.x - a.x)
            dy += abs(b.y - a.y)
        }
        return dy <= dx * drift
    }

    // MARK: - Live

    private var points: [Point] = []
    private var lastShake: TimeInterval = -.infinity

    /// Adds a point of the drag; true once it ends a shake. After one, the next must be a fresh shake.
    mutating func add(t: TimeInterval, x: Double, y: Double) -> Bool {
        points.append(Point(t: t, x: x, y: y))
        points.removeAll { t - $0.t > Self.window }
        guard t - lastShake > 0.8, Self.isShake(points) else { return false }
        lastShake = t
        points.removeAll()
        return true
    }

    mutating func reset() {
        points.removeAll()
    }
}

// MARK: - Synthetic checks

extension ShakeDetector {
    /// Made-up drags at 120 events a second, with whether each should count as a shake.
    static let syntheticCases: [(name: String, shake: Bool, points: [Point])] = {
        func path(_ seconds: Double, _ f: (Double) -> (Double, Double)) -> [Point] {
            stride(from: 0.0, through: seconds, by: 1.0 / 120).map { t in
                let (x, y) = f(t)
                return Point(t: t, x: x, y: y)
            }
        }
        let tau = 2 * Double.pi
        return [
            ("shake 4 Hz ±60pt", true, path(1) { t in (600 + 60 * sin(tau * 4 * t), 400 + 6 * sin(tau * 9 * t)) }),
            ("gentle shake 3 Hz ±30pt", true, path(1) { t in (600 + 30 * sin(tau * 3 * t), 400) }),
            ("trackpad shake 5 Hz ±25pt, drifting up", true, path(1) { t in (600 + 25 * sin(tau * 5 * t), 400 + 30 * t) }),
            ("shake while moving right", true, path(1) { t in (300 + 200 * t + 50 * sin(tau * 4 * t), 400) }),
            ("fast straight drag 900pt in 0.35 s", false, path(0.35) { t in (100 + 900 * t / 0.35, 300 + 200 * t) }),
            ("fast drag, overshoot and correct", false, path(0.6) { t in
                let x = t < 0.3 ? 100 + 760 * t / 0.3 : t < 0.42 ? 860 - 60 * (t - 0.3) / 0.12 : 800 + 8 * sin(tau * 6 * t)
                return (x, 500)
            }),
            ("drag left then back right to a target", false, path(0.9) { t in
                let x = t < 0.4 ? 900 - 500 * t / 0.4 : t < 0.7 ? 400 + 300 * (t - 0.4) / 0.3 : 700 - 15 * (t - 0.7)
                return (x, 500 - 100 * t)
            }),
            ("aiming jitter ±12pt at 8 Hz", false, path(1.5) { t in (700 + 12 * sin(tau * 8 * t), 600 + 5 * cos(tau * 7 * t)) }),
            ("slow wiggle 1 Hz ±80pt", false, path(3) { t in (700 + 80 * sin(tau * 1 * t), 600) }),
            ("medium wiggle 1.5 Hz ±60pt", false, path(3) { t in (700 + 60 * sin(tau * 1.5 * t), 600) }),
            ("vertical shake 4 Hz ±60pt", false, path(1) { t in (700 + 5 * sin(tau * 3 * t), 500 + 60 * sin(tau * 4 * t)) }),
            ("circles 3 Hz r 60pt", false, path(1) { t in (700 + 60 * cos(tau * 3 * t), 500 + 60 * sin(tau * 3 * t)) }),
        ]
    }()

    /// Runs every synthetic drag through the live detector: one line each, with when it fired.
    static func runSynthetic() -> [String] {
        syntheticCases.map { c in
            var d = ShakeDetector()
            let at = c.points.first { d.add(t: $0.t, x: $0.x, y: $0.y) }?.t
            let ok = (at != nil) == c.shake
            return "\(ok ? "PASS" : "FAIL") \(c.name): \(at.map { String(format: "shake at %.2fs", $0) } ?? "no shake") (want \(c.shake ? "shake" : "none"))"
        }
    }
}
