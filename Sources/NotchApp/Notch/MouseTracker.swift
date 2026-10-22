import AppKit

enum MouseEventKind {
    case moved, dragged, down, up, tick
}

/// Watches the mouse globally so the notch can react to hovering and drags
/// while its window ignores mouse events (letting clicks reach the menu bar).
@MainActor
final class MouseTracker {
    private var monitors: [Any] = []
    private var timer: Timer?
    private var dragChangeCount = 0
    private var dragStartedInNotch = false
    private var shake = ShakeDetector()

    /// The pointer was shaken mid-drag (a drag from another app): where it is now.
    var onShake: ((NSPoint) -> Void)?

    /// True while the user drags something (text, links, files, emails) from another app.
    private(set) static var isExternalDrag = false {
        didSet { if DragActivity.shared.active != isExternalDrag { DragActivity.shared.active = isExternalDrag } }
    }
    /// Bumped whenever a new external drag begins, so views can refresh their preview.
    private(set) static var dragGeneration = 0

    func start(_ handler: @escaping (MouseEventKind) -> Void) {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]

        let process: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let kind: MouseEventKind
            switch event.type {
            case .leftMouseDown:
                self.dragChangeCount = NSPasteboard(name: .drag).changeCount
                // Local events carry our window; drags out of the shelf shouldn't reopen drop bins.
                self.dragStartedInNotch = event.window is NotchPanel || event.window is ShelfTrayPanel
                self.shake.reset()
                Self.isExternalDrag = false
                kind = .down
            case .leftMouseUp:
                Self.isExternalDrag = false
                kind = .up
            case .leftMouseDragged:
                if !Self.isExternalDrag, !self.dragStartedInNotch {
                    let pb = NSPasteboard(name: .drag)
                    if pb.changeCount != self.dragChangeCount, !(pb.types ?? []).isEmpty {
                        Self.isExternalDrag = true
                        Self.dragGeneration += 1
                    }
                }
                // Only another app's drags: a local event (one in our own windows) carries its window.
                if Self.isExternalDrag, event.window == nil, let onShake {
                    let p = NSEvent.mouseLocation
                    if self.shake.add(t: event.timestamp, x: p.x, y: p.y) { onShake(p) }
                }
                kind = .dragged
            default:
                kind = .moved
            }
            handler(kind)
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { process(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { process(event) }
            return event
        }) {
            monitors.append(local)
        }

        // Safety net for edge cases (screen edges, missed exit events).
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons == 0 { Self.isExternalDrag = false }
                handler(.tick)
            }
        }
        RunLoop.main.add(t, forMode: .default) // paused during menu tracking on purpose
        timer = t
    }
}

/// Something is being dragged that the notch could take, for views that only show their drop
/// targets then. External drags come from `MouseTracker`; a drag out of the notch itself (a clip
/// card) sets it as it starts, and the tracker clears it once the mouse is let go.
@MainActor
final class DragActivity: ObservableObject {
    static let shared = DragActivity()
    @Published var active = false
}
