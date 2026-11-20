import AppKit

/// One finger along the trackpad's edges moves a level: up the right edge for volume, up the left
/// for the display's brightness, and along the top edge, against the keys, for their backlight.
/// A slide only counts once the finger has started at an edge and run along it; anything else is
/// the pointer as usual. While it counts, the event tap holds the pointer still.
///
/// Fed from `Multitouch`'s contact frames, on the multitouch thread.
enum EdgeSliders {
    nonisolated(unsafe) static var enabled = false
    /// A slide is under way: the pointer's moves are dropped.
    nonisolated(unsafe) private(set) static var sliding = false

    private enum Edge { case left, right, top }

    nonisolated(unsafe) private static var edge: Edge?
    nonisolated(unsafe) private static var start: CGPoint = .zero
    nonisolated(unsafe) private static var last: CGPoint = .zero
    nonisolated(unsafe) private static var finger: Int32 = -1
    /// Movement not yet handed to the main thread, in trackpad widths/heights.
    nonisolated(unsafe) private static var pending: CGFloat = 0
    nonisolated(unsafe) private static var flushing = false

    /// How far in from each side an edge reaches (a fraction of the pad), and how far a finger
    /// must run along it before it's a slide rather than the start of a pointer move.
    private static let side: CGFloat = 0.06, top: CGFloat = 0.09, arm: CGFloat = 0.035

    /// MultitouchSupport's per-finger record (96 bytes): the identifier at 16, the state at 20
    /// (4 down, 5 touching), the position normalised 0…1 at 32 (y up, from the near edge), the
    /// contact's size at 48.
    private static let stride = 96

    static func frame(_ touches: UnsafeMutableRawPointer?, count: Int32) {
        guard count == 1, let touches else { return end() }
        let id = touches.load(fromByteOffset: 16, as: Int32.self)
        let state = touches.load(fromByteOffset: 20, as: Int32.self)
        let p = CGPoint(x: CGFloat(touches.load(fromByteOffset: 32, as: Float.self)),
                        y: CGFloat(touches.load(fromByteOffset: 36, as: Float.self)))
        let size = touches.load(fromByteOffset: 48, as: Float.self)
        // A palm or a resting thumb is broad; a lifting finger is no longer touching.
        guard state == 4 || state == 5, size < 1.6 else { return end() }

        if id != finger {
            // A new finger: does it start at an edge?
            end()
            finger = id
            start = p
            last = p
            edge = p.x > 1 - side ? .right : p.x < side ? .left : p.y > 1 - top ? .top : nil
            return
        }
        guard let edge else { return }
        defer { last = p }
        let along = edge == .top ? p.x - start.x : p.y - start.y
        let across = edge == .top ? p.y : p.x
        let stillOnEdge = switch edge {
        case .right: across > 1 - side * 2.2
        case .left: across < side * 2.2
        case .top: across > 1 - top * 2
        }
        guard stillOnEdge else {
            // It wandered off the edge: a pointer move after all (unless it already was a slide).
            if !sliding { self.edge = nil }
            return
        }
        if !sliding {
            guard abs(along) > arm else { return }
            sliding = true
        }
        pending += edge == .top ? p.x - last.x : p.y - last.y
        flush(edge)
    }

    private static func end() {
        sliding = false
        edge = nil
        finger = -1
        pending = 0
    }

    /// Hands the movement to the main thread at most once per run of its loop.
    private static func flush(_ edge: Edge) {
        guard !flushing else { return }
        flushing = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let delta = Float(pending)
                pending = 0
                flushing = false
                apply(edge, delta: delta)
            }
        }
    }

    /// The whole height of the pad's edge is about the whole range: a slide from bottom to top
    /// takes a level from nothing to full (the top edge, being wider, a little more than that).
    @MainActor private static func apply(_ edge: Edge, delta: Float) {
        guard delta != 0 else { return }
        switch edge {
        case .right:
            guard AudioOutputManager.canSetVolume else { return }
            let v = min(1, max(0, AudioOutputManager.volume + delta * 1.2))
            AudioOutputManager.isMuted = v <= 0.001
            AudioOutputManager.volume = v
            ActivityCenter.shared.show(.volume(level: v, muted: v <= 0.001), for: 1.6)
        case .left:
            guard Brightness.isAvailable, let current = Brightness.get() else { return }
            let b = min(1, max(0, current + delta * 1.2))
            Brightness.set(b)
            ActivityCenter.shared.show(.brightness(level: b), for: 1.6)
        case .top:
            KeyboardBacklight.shared.step(by: delta * 1.1)
        }
    }
}
