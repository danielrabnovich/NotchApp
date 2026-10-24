import AppKit

/// Keys that do nothing for a minute, so the keyboard can be wiped down: typing, modifiers, and the
/// media and brightness keys. The mouse and trackpad still work, and clicking the tile (or the
/// Banner) ends it early. Needs Accessibility, like the media keys.
@MainActor
final class KeyboardCleaner: ObservableObject {
    static let shared = KeyboardCleaner()

    static let length: TimeInterval = 60

    @Published private(set) var endsAt: Date?
    @Published private(set) var now = Date()

    var isActive: Bool { endsAt != nil }

    var remainingText: String {
        "0:" + String(format: "%02d", max(0, Int((endsAt ?? now).timeIntervalSince(now).rounded(.up))))
    }

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?

    private init() {}

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        guard AXIsProcessTrusted() else { return Permissions.shared.request(.accessibility) }
        // Key down and up, modifiers, and NX_SYSDEFINED (media, brightness, volume).
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
                               | 1 << CGEventType.flagsChanged.rawValue | 1 << 14)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: keyboardCleanerCallback, userInfo: nil) else { return }
        self.port = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        endsAt = Date().addingTimeInterval(Self.length)
        now = Date()
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { KeyboardCleaner.shared.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        ActivityCenter.shared.show(.notice(title: "Keyboard off for a minute", detail: "Click here or the tile to turn it back on",
                                           icon: "keyboard", tone: .info), for: 5) { KeyboardCleaner.shared.stop() }
    }

    func stop() {
        guard isActive else { return }
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        timer?.invalidate()
        timer = nil
        endsAt = nil
        ActivityCenter.shared.show(.notice(title: "Keyboard back on", detail: "Typing works again", icon: "keyboard", tone: .success), for: 2)
    }

    private func tick() {
        now = Date()
        if let endsAt, now >= endsAt { stop() }
    }

    /// macOS switched the tap off (it was slow, or secure input): back on while cleaning.
    fileprivate func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }
}

private func keyboardCleanerCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                     refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { KeyboardCleaner.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    return nil
}
