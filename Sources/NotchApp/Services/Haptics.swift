import AppKit

/// Trackpad taps (Force Touch trackpads only; felt while a finger rests on it, which it does while
/// hovering or swiping). Turned off in Settings → Motion.
@MainActor
enum Haptics {
    /// A light detent: the notch opening under the pointer, a page snapping into place.
    static func align() { perform(.alignment) }
    /// A button-like tap: a tab or a Glance clicked, a toggle flipped.
    static func tap() { perform(.generic) }
    /// A step: a drop landing, a value crossing a threshold, something arriving.
    static func level() { perform(.levelChange) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard AppSettings.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
