import AppKit
import QuartzCore
import SwiftUI

/// The app's springs, in one place, following the Animation choice in Settings (Smooth, Snappy,
/// Bouncy) and the system's Reduce Motion. Each is a duration and a bounce, so SwiftUI and Core
/// Animation (the pager, the tab pill) move with exactly the same curve.
@MainActor
struct Motion {
    /// How long it takes to look settled, and how far past the target it goes (0 none, 1 a lot).
    let duration: Double
    let bounce: Double

    var animation: Animation { .spring(duration: duration, bounce: bounce) }

    /// The same spring for Core Animation; `velocity` is in units of the whole distance per second.
    func caSpring(keyPath: String, velocity: Double = 0) -> CASpringAnimation {
        let a = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        a.keyPath = keyPath
        a.initialVelocity = velocity
        a.duration = a.settlingDuration
        a.fillMode = .backwards
        return a
    }

    private static var style: AppSettings.AnimationStyle { AppSettings.shared.animationStyle }

    /// The system's Reduce Motion: pages and panes fade instead of sliding, and nothing bounces.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The notch opening.
    static var open: Motion {
        if reduced { return Motion(duration: 0.3, bounce: 0) }
        switch style {
        case .smooth: return Motion(duration: 0.42, bounce: 0.18)
        case .snappy: return Motion(duration: 0.32, bounce: 0.12)
        case .bouncy: return Motion(duration: 0.44, bounce: 0.32)
        }
    }

    /// The notch closing: never bouncy, a closing notch that overshoots reads as a glitch.
    static var close: Motion {
        switch style {
        case .snappy: Motion(duration: 0.3, bounce: 0)
        default: Motion(duration: 0.38, bounce: 0.05)
        }
    }

    /// Pages sliding (a swipe let go, or a tab clicked) and the pill over the tab buttons.
    static var page: Motion {
        if reduced { return Motion(duration: 0.25, bounce: 0) }
        switch style {
        case .smooth: return Motion(duration: 0.42, bounce: 0.1)
        case .snappy: return Motion(duration: 0.3, bounce: 0.04)
        case .bouncy: return Motion(duration: 0.46, bounce: 0.26)
        }
    }

    /// Panes inside a page (Tasks · Notes, Network · Cleaner), lists pushed in and out, overlays.
    static var pane: Motion {
        if reduced { return Motion(duration: 0.22, bounce: 0) }
        switch style {
        case .smooth: return Motion(duration: 0.34, bounce: 0.12)
        case .snappy: return Motion(duration: 0.26, bounce: 0.06)
        case .bouncy: return Motion(duration: 0.38, bounce: 0.28)
        }
    }

    /// Small things: a card growing, a row expanding, a value changing.
    static var small: Motion {
        if reduced { return Motion(duration: 0.18, bounce: 0) }
        switch style {
        case .smooth: return Motion(duration: 0.3, bounce: 0.12)
        case .snappy: return Motion(duration: 0.22, bounce: 0.05)
        case .bouncy: return Motion(duration: 0.34, bounce: 0.3)
        }
    }

    /// One pane giving way to another in the same place: the new one eases in from a little way
    /// toward the side it lies on (`forward`: to the right), the old one fades.
    static func paneSwap(forward: Bool) -> AnyTransition {
        if reduced { return .opacity }
        return .asymmetric(insertion: .offset(x: forward ? 18 : -18).combined(with: .opacity),
                           removal: .opacity.animation(.easeOut(duration: 0.12)))
    }

    /// A pane or list coming in: from the side it lies on, or only a fade with Reduce Motion.
    static func paneTransition(edge: Edge) -> AnyTransition {
        reduced ? .opacity : .opacity.combined(with: .move(edge: edge))
    }
}
