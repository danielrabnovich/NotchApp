import AppKit
import ApplicationServices

/// Snaps the window in front to halves, thirds, quarters, the full screen, the centre or another
/// display, through Accessibility. Left or right again sends the window on to the display that way
/// (or, with none there, to ⅔ and then ⅓). Each window's frame before it was snapped is kept, so
/// Restore puts it back.
@MainActor
enum WindowManager {
    enum Action: String, CaseIterable, Equatable {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case maximize, almostMaximize, center
        case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
        case topLeft, topRight, bottomLeft, bottomRight
        case nextDisplay, previousDisplay, restore

        var title: String {
            switch self {
            case .leftHalf: "Left Half"
            case .rightHalf: "Right Half"
            case .topHalf: "Top Half"
            case .bottomHalf: "Bottom Half"
            case .maximize: "Maximize"
            case .almostMaximize: "Almost Maximize"
            case .center: "Center"
            case .leftThird: "Left Third"
            case .centerThird: "Center Third"
            case .rightThird: "Right Third"
            case .leftTwoThirds: "Left Two Thirds"
            case .rightTwoThirds: "Right Two Thirds"
            case .topLeft: "Top Left Quarter"
            case .topRight: "Top Right Quarter"
            case .bottomLeft: "Bottom Left Quarter"
            case .bottomRight: "Bottom Right Quarter"
            case .nextDisplay: "Next Display"
            case .previousDisplay: "Previous Display"
            case .restore: "Restore"
            }
        }

        /// What people type for it, besides the title.
        var words: [String] {
            switch self {
            case .leftHalf: ["left", "snap left"]
            case .rightHalf: ["right", "snap right"]
            case .topHalf: ["top"]
            case .bottomHalf: ["bottom"]
            case .maximize: ["maximise", "full screen", "fill", "fullscreen"]
            case .almostMaximize: ["almost maximise", "almost full"]
            case .center: ["centre", "center window", "centre window"]
            case .leftThird: ["first third"]
            case .centerThird: ["centre third", "middle third"]
            case .rightThird: ["last third"]
            case .leftTwoThirds: ["first two thirds"]
            case .rightTwoThirds: ["last two thirds"]
            case .topLeft: ["top left"]
            case .topRight: ["top right"]
            case .bottomLeft: ["bottom left"]
            case .bottomRight: ["bottom right"]
            case .nextDisplay: ["other display", "next screen", "other screen", "move to display"]
            case .previousDisplay: ["previous screen", "last display", "back a display"]
            case .restore: ["restore window", "undo window", "original size"]
            }
        }

        /// How much of the screen's width, for a step of left or right pressed again.
        var share: String? {
            switch self {
            case .leftHalf, .rightHalf: "½"
            case .leftTwoThirds, .rightTwoThirds: "⅔"
            case .leftThird, .rightThird: "⅓"
            default: nil
            }
        }

        var icon: String {
            switch self {
            case .leftHalf: "rectangle.lefthalf.filled"
            case .rightHalf: "rectangle.righthalf.filled"
            case .topHalf: "rectangle.tophalf.filled"
            case .bottomHalf: "rectangle.bottomhalf.filled"
            case .maximize, .almostMaximize: "rectangle.fill"
            case .center: "rectangle.center.inset.filled"
            case .leftThird: "rectangle.leftthird.inset.filled"
            case .rightThird: "rectangle.rightthird.inset.filled"
            case .centerThird, .leftTwoThirds, .rightTwoThirds: "rectangle.split.3x1.fill"
            case .topLeft: "rectangle.inset.topleft.filled"
            case .topRight: "rectangle.inset.topright.filled"
            case .bottomLeft: "rectangle.inset.bottomleft.filled"
            case .bottomRight: "rectangle.inset.bottomright.filled"
            case .nextDisplay, .previousDisplay: "display.2"
            case .restore: "arrow.uturn.backward"
            }
        }
    }

    /// Frames before the first snap, by window, for Restore.
    private static var original: [CGWindowID: CGRect] = [:]
    /// Each window's last snap and where it ended up: the same key again on a window still there is
    /// a repeat; a window somewhere else has been moved by hand since.
    private static var last: [CGWindowID: (action: Action, frame: CGRect)] = [:]

    /// `pid`: another app's window than the one in front (debug hooks).
    static func apply(_ action: Action, pid: pid_t? = nil) {
        guard AXIsProcessTrusted() else {
            ActivityCenter.shared.show(.notice(title: "Allow Accessibility", detail: "Needed to move windows", icon: "lock.shield", tone: .warning), for: 3)
            return
        }
        guard let app = pid.flatMap(NSRunningApplication.init(processIdentifier:))
                ?? NSWorkspace.shared.frontmostApplication.flatMap({ $0.processIdentifier == getpid() ? FrontmostTracker.shared.lastOther : $0 })
        else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        guard let window = element(axApp, kAXFocusedWindowAttribute) ?? element(axApp, kAXMainWindowAttribute),
              AXReader.value(window, "AXFullScreen") != true,
              let frame = frame(of: window) else { return }
        var id: CGWindowID = 0
        let hasID = _AXUIElementGetWindow(window, &id) == .success
        let previous = hasID ? last[id] : nil
        let untouched = previous.map { close($0.frame, frame) } ?? false

        let screens = NSScreen.screens
        guard let current = screens.max(by: { overlap($0, frame) < overlap($1, frame) }) ?? NSScreen.main else { return }
        var done = action
        var destination = current
        var area = visible(current)
        var target: CGRect
        switch action {
        case .restore:
            guard hasID, let saved = original.removeValue(forKey: id) else { return }
            last[id] = nil
            target = saved
        case .nextDisplay, .previousDisplay:
            let ordered = screens.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
            guard ordered.count > 1, let i = ordered.firstIndex(of: current) else { return }
            let next = ordered[(i + (action == .nextDisplay ? 1 : ordered.count - 1)) % ordered.count]
            let from = visible(current)
            destination = next
            area = visible(next)
            // Same place and size relative to the screen, scaled to fit.
            let scale = min(1, min(area.width / max(frame.width, 1), area.height / max(frame.height, 1)))
            let size = CGSize(width: frame.width * scale, height: frame.height * scale)
            let rel = CGPoint(x: (frame.minX - from.minX) / max(from.width - frame.width, 1),
                              y: (frame.minY - from.minY) / max(from.height - frame.height, 1))
            target = CGRect(x: area.minX + max(0, min(1, rel.x)) * (area.width - size.width),
                            y: area.minY + max(0, min(1, rel.y)) * (area.height - size.height), width: size.width, height: size.height)
        case .leftHalf, .rightHalf:
            let left = action == .leftHalf
            let cycle: [Action] = left ? [.leftHalf, .leftTwoThirds, .leftThird] : [.rightHalf, .rightTwoThirds, .rightThird]
            if untouched, let previous, let step = cycle.firstIndex(of: previous.action) {
                if step == 0, let beside = neighbor(of: current, left: left) {
                    // On to the display that way, against the side it came in from.
                    done = left ? .rightHalf : .leftHalf
                    destination = beside
                    area = visible(beside)
                } else {
                    done = cycle[(step + 1) % cycle.count]
                }
            }
            target = rect(for: done, in: area, window: frame)
        default:
            target = rect(for: action, in: area, window: frame)
        }
        // Moved by hand since the last snap (or never snapped): this is where Restore goes back to.
        if hasID, action != .restore, !untouched { original[id] = frame }

        // Chrome and Electron apps animate (and end up the wrong size) while this is on.
        let enhanced = AXReader.value(axApp, "AXEnhancedUserInterface") == true
        if enhanced { AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        set(window, to: target)
        // An app that won't take the size (a minimum, or Terminal's character grid) keeps to the
        // edges it was sent to, rather than hanging off the far side.
        var landed = Self.frame(of: window) ?? target
        if action != .restore, !close(landed, target) {
            var origin = CGPoint(x: aligned(landed.width, target.minX, target.maxX, area.minX, area.maxX),
                                 y: aligned(landed.height, target.minY, target.maxY, area.minY, area.maxY))
            if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
            landed = Self.frame(of: window) ?? landed
        }
        if enhanced { AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        if hasID, action != .restore { last[id] = (done, landed) }
        DebugHooks.log("Window: \(action) → \(done) \(landed) enhanced=\(enhanced)")
        Haptics.align()
        // Only when the key did more than its plain snap: a plain one shows for itself.
        if destination != current {
            ActivityCenter.shared.show(.window(icon: done.icon, label: destination.localizedName), for: 1.2)
        } else if done != action, let share = done.share {
            ActivityCenter.shared.show(.window(icon: done.icon, label: share), for: 1.2)
        }
    }

    /// Where a window of `length` starts along one axis: at the edge the target shares with the
    /// screen, else centred on the target, kept on the screen while it fits.
    private static func aligned(_ length: CGFloat, _ min: CGFloat, _ max: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        let start: CGFloat = abs(min - lower) < 2 ? lower : abs(max - upper) < 2 ? upper - length : (min + max - length) / 2
        return length >= upper - lower ? lower : Swift.min(Swift.max(start, lower), upper - length)
    }

    /// Within a couple of points: apps round sizes to their own steps.
    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// The nearest display that way, as the displays are arranged.
    private static func neighbor(of screen: NSScreen, left: Bool) -> NSScreen? {
        NSScreen.screens
            .filter { left ? $0.frame.maxX <= screen.frame.midX : $0.frame.minX >= screen.frame.midX }
            .min { abs($0.frame.midX - screen.frame.midX) < abs($1.frame.midX - screen.frame.midX) }
    }

    /// The rectangle for an action within a screen's usable area (top-left coordinates).
    private static func rect(for action: Action, in r: CGRect, window: CGRect) -> CGRect {
        let w = r.width, h = r.height
        switch action {
        case .leftHalf: return CGRect(x: r.minX, y: r.minY, width: w / 2, height: h)
        case .rightHalf: return CGRect(x: r.midX, y: r.minY, width: w / 2, height: h)
        case .topHalf: return CGRect(x: r.minX, y: r.minY, width: w, height: h / 2)
        case .bottomHalf: return CGRect(x: r.minX, y: r.midY, width: w, height: h / 2)
        case .maximize: return r
        case .almostMaximize: return r.insetBy(dx: w * 0.05, dy: h * 0.05)
        case .center:
            let size = CGSize(width: min(window.width, w), height: min(window.height, h))
            return CGRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height)
        case .leftThird: return CGRect(x: r.minX, y: r.minY, width: w / 3, height: h)
        case .centerThird: return CGRect(x: r.minX + w / 3, y: r.minY, width: w / 3, height: h)
        case .rightThird: return CGRect(x: r.minX + 2 * w / 3, y: r.minY, width: w / 3, height: h)
        case .leftTwoThirds: return CGRect(x: r.minX, y: r.minY, width: 2 * w / 3, height: h)
        case .rightTwoThirds: return CGRect(x: r.minX + w / 3, y: r.minY, width: 2 * w / 3, height: h)
        case .topLeft: return CGRect(x: r.minX, y: r.minY, width: w / 2, height: h / 2)
        case .topRight: return CGRect(x: r.midX, y: r.minY, width: w / 2, height: h / 2)
        case .bottomLeft: return CGRect(x: r.minX, y: r.midY, width: w / 2, height: h / 2)
        case .bottomRight: return CGRect(x: r.midX, y: r.midY, width: w / 2, height: h / 2)
        case .nextDisplay, .previousDisplay, .restore: return window
        }
    }

    /// A screen's usable area (without the menu bar and Dock) in Accessibility's top-left coordinates.
    private static func visible(_ screen: NSScreen) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: top - v.maxY, width: v.width, height: v.height)
    }

    private static func overlap(_ screen: NSScreen, _ window: CGRect) -> CGFloat {
        let i = visible(screen).intersection(window)
        return i.isNull ? 0 : i.width * i.height
    }

    // MARK: - Accessibility

    private static func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Size, then position, then size again: a window too big for where it's going would be
    /// clamped by the first move otherwise.
    private static func set(_ window: AXUIElement, to r: CGRect) {
        var size = r.size, origin = r.origin
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
