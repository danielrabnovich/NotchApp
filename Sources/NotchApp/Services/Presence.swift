import AppKit
import Combine

/// Whether anyone can see the Mac: not while it's locked, the screen saver runs or the displays
/// sleep. Work that only feeds what's on screen (stats sampling, polling other apps' badges and
/// exports, the Glances' clock) waits while nobody's there, and catches up the moment they're back.
@MainActor
final class Presence: ObservableObject {
    static let shared = Presence()

    @Published private(set) var away = false
    /// Locked (or the screen saver is up); the displays may still be on.
    @Published private(set) var locked = false { didSet { update() } }
    private var asleep = false { didSet { update() } }
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard tokens.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        func watch(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor () -> Void) {
            tokens.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { body() }
            }))
        }
        watch(ws, NSWorkspace.screensDidSleepNotification) { Presence.shared.asleep = true }
        watch(ws, NSWorkspace.screensDidWakeNotification) { Presence.shared.asleep = false }
        watch(ws, NSWorkspace.sessionDidResignActiveNotification) { Presence.shared.locked = true }
        watch(ws, NSWorkspace.sessionDidBecomeActiveNotification) { Presence.shared.locked = false }
        for (name, isLocked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false),
                                 ("com.apple.screensaver.didstart", true), ("com.apple.screensaver.didstop", false)] {
            watch(dnc, Notification.Name(name)) { Presence.shared.locked = isLocked }
        }
    }

    private func update() {
        let now = locked || asleep
        if now != away { away = now }
    }
}
