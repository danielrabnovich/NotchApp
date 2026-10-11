import AppKit
import ApplicationServices

/// Snaps the window in front to halves, thirds, quarters, the full screen, the centre or the next
/// display, through Accessibility. Each window's frame before its first snap is kept, so Restore
/// puts it back.
@MainActor
enum WindowManager {
    enum Action: String, CaseIterable, Equatable {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case maximize, almostMaximize, center
        case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
        case topLeft, topRight, bottomLeft, bottomRight
        case nextDisplay, restore

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
            case .restore: ["restore window", "undo window", "original size"]
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
            case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds: "rectangle.split.3x1.fill"
            case .topLeft: "rectangle.inset.topleft.filled"
            case .topRight: "rectangle.inset.topright.filled"
            case .bottomLeft: "rectangle.inset.bottomleft.filled"
            case .bottomRight: "rectangle.inset.bottomright.filled"
            case .nextDisplay: "display.2"
            case .restore: "arrow.uturn.backward"
            }
        }
    }

    /// Frames before the first snap, by window, for Restore.
    private static var original: [CGWindowID: CGRect] = [:]

    static func apply(_ action: Action) {
        guard AXIsProcessTrusted() else {
            ActivityCenter.shared.show(.notice(title: "Allow Accessibility", detail: "Needed to move windows", icon: "lock.shield", tone: .warning), for: 3)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication.flatMap({ $0.processIdentifier == getpid() ? FrontmostTracker.shared.lastOther : $0 })
        else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        guard let window = element(axApp, kAXFocusedWindowAttribute) ?? element(axApp, kAXMainWindowAttribute),
              let frame = frame(of: window) else { return }
        var id: CGWindowID = 0
        let hasID = _AXUIElementGetWindow(window, &id) == .success

        let screens = NSScreen.screens
        let current = screens.max { overlap($0, frame) < overlap($1, frame) } ?? NSScreen.main
        guard let current else { return }
        var target: CGRect
        switch action {
        case .restore:
            guard hasID, let saved = original.removeValue(forKey: id) else { return }
            target = saved
        case .nextDisplay:
            guard screens.count > 1, let i = screens.firstIndex(of: current) else { return }
            let next = screens[(i + 1) % screens.count]
            let from = visible(current), to = visible(next)
            // Same place and size relative to the screen, scaled to fit.
            let scale = min(1, min(to.width / max(frame.width, 1), to.height / max(frame.height, 1)))
            let size = CGSize(width: frame.width * scale, height: frame.height * scale)
            let rel = CGPoint(x: (frame.minX - from.minX) / max(from.width - frame.width, 1),
                              y: (frame.minY - from.minY) / max(from.height - frame.height, 1))
            target = CGRect(x: to.minX + max(0, min(1, rel.x)) * (to.width - size.width),
                            y: to.minY + max(0, min(1, rel.y)) * (to.height - size.height), width: size.width, height: size.height)
        default:
            target = rect(for: action, in: visible(current), window: frame)
        }
        if hasID, action != .restore, original[id] == nil { original[id] = frame }
        set(window, to: target)
        Haptics.align()
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
        case .nextDisplay, .restore: return window
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
