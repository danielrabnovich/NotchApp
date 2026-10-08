import AppKit
import SwiftUI

/// Borderless, transparent, non-activating panel that floats above the menu bar.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        // Re-applying the style after init is what actually registers the panel as non-activating
        // with the window server; without it, focusing the search bar activated the whole app,
        // and every open/close became an app switch (menu bar redraw and all) that dropped frames.
        styleMask = [.borderless, .nonactivatingPanel]
        becomesKeyOnlyIfNeeded = false
    }

    /// Escape that no text field handled (it travels up the responder chain to here).
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { onCancel?() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘, opens Settings. The app's menu only handles key equivalents while the app is active, and
    /// this panel deliberately never activates it, so the panel catches it itself.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "," {
            MainActor.assumeIsolated {
                NotchPresenter.shared.primary?.close()
                SettingsWindowController.shared.show()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Allow the window to sit over the menu bar / notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosting view that reacts to the first click even while the app is in the background.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
    var hasNotch: Bool { safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil }

    /// Size of the hardware notch, or a sensible fake-notch size for displays without one.
    var notchSize: CGSize {
        if hasNotch, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
            return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
        }
        let menuBar = frame.maxY - visibleFrame.maxY
        return CGSize(width: 190, height: max(24, min(menuBar, 32)))
    }

    /// Horizontal centre of the notch in global screen coordinates.
    var notchCenterX: CGFloat {
        if hasNotch, let left = auxiliaryTopLeftArea {
            return frame.minX + left.width + notchSize.width / 2
        }
        return frame.midX
    }

    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
