import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.hid

/// Caps Lock as a Hyper key: held, it's ⌃⌥⇧⌘, for ✦ shortcuts here and in any other app.
///
/// The keyboard driver is told to send F18 for Caps Lock (a per-keyboard key mapping, as `hidutil`
/// sets; no permission needed), and an event tap (needs Accessibility) turns F18 into the four
/// modifiers and adds them to every key pressed while it's held. Tinycast, Raycast and Hyperkey do
/// the same; only one of them should be on.
@MainActor
final class HyperKey {
    static let shared = HyperKey()

    private var tap: (port: CFMachPort, source: CFRunLoopSource)?
    private var retryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        AppSettings.shared.$capsLockHyper.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reconfigure() } }
            .store(in: &cancellables)
        // A keyboard plugged in (or woken) after the mapping was set doesn't have it yet.
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reconfigure() } }
            .store(in: &cancellables)
    }

    /// Gives Caps Lock back (on quit, or when turned off).
    func stop() {
        uninstall()
        Self.setMapping(false)
    }

    private func reconfigure() {
        guard AppSettings.shared.capsLockHyper else { return stop() }
        if tap == nil { install() }
        // Only with the tap there to turn F18 into Hyper: without it Caps Lock would do nothing at all.
        Self.setMapping(tap != nil)
    }

    private func install() {
        // Without Accessibility access the tap can't be created; retry once it's granted.
        guard AXIsProcessTrusted() else {
            retryTimer?.invalidate()
            let t = Timer(timeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    HyperKey.shared.retryTimer?.invalidate()
                    HyperKey.shared.retryTimer = nil
                    HyperKey.shared.reconfigure()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            retryTimer = t
            return
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: hyperTapCallback, userInfo: nil),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            DebugHooks.log("HyperKey: couldn't create the event tap")
            return
        }
        CFRunLoopAddSource(TapThread.runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = (port, source)
        HyperTapState.port = port
        DebugHooks.log("HyperKey: on")
    }

    private func uninstall() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard let tap else { return }
        HyperTapState.port = nil
        HyperTapState.held = false
        CGEvent.tapEnable(tap: tap.port, enable: false)
        CFRunLoopRemoveSource(TapThread.runLoop, tap.source, .commonModes)
        CFMachPortInvalidate(tap.port)
        self.tap = nil
        DebugHooks.log("HyperKey: off")
    }

    // MARK: - Caps Lock → F18 in the keyboard driver

    private static let capsLock: UInt64 = 0x7_0000_0039
    private static let f18: UInt64 = 0x7_0000_006D
    private static let srcKey = "HIDKeyboardModifierMappingSrc"
    private static let dstKey = "HIDKeyboardModifierMappingDst"
    /// Whether NotchApp added the mapping (rather than finding it there, put by Tinycast or the
    /// like), so turning off only takes away its own.
    private static let ownedKey = "capsLockHyper.mapped"

    /// Adds or removes Caps Lock → F18 on every keyboard, keeping any other mappings they have.
    private static func setMapping(_ on: Bool) {
        let defaults = UserDefaults.standard
        let owned = defaults.bool(forKey: ownedKey)
        guard on || owned else { return }
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return }
        var added = false
        for service in services where IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0 {
            let key = "UserKeyMapping" as CFString
            var mapping = (IOHIDServiceClientCopyProperty(service, key) as? [[String: Any]]) ?? []
            let isOurs: ([String: Any]) -> Bool = {
                ($0[srcKey] as? NSNumber)?.uint64Value == capsLock && ($0[dstKey] as? NSNumber)?.uint64Value == f18
            }
            let has = mapping.contains(where: isOurs)
            if on, !has {
                // Caps Lock mapped to something else is the user's choice; leave that keyboard alone.
                guard !mapping.contains(where: { ($0[srcKey] as? NSNumber)?.uint64Value == capsLock }) else { continue }
                mapping.append([srcKey: NSNumber(value: capsLock), dstKey: NSNumber(value: f18)])
                added = true
            } else if !on, has {
                mapping.removeAll(where: isOurs)
            } else {
                continue
            }
            IOHIDServiceClientSetProperty(service, key, mapping as CFArray)
        }
        if on, added { defaults.set(true, forKey: ownedKey) }
        if !on { defaults.removeObject(forKey: ownedKey) }
    }
}

/// Read and written on the tap thread (`port` is set from the main thread before the tap runs).
enum HyperTapState {
    nonisolated(unsafe) static var port: CFMachPort?
    /// Caps Lock (F18) is down.
    nonisolated(unsafe) static var held = false
    static let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
}

private func hyperTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                              _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let port = HyperTapState.port { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    case .keyDown, .keyUp:
        if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_F18) {
            let down = type == .keyDown
            // Key repeat while it's held: nothing new to say.
            if down, HyperTapState.held { return nil }
            HyperTapState.held = down
            // The press itself becomes the four modifiers going down (or up), so apps watching
            // modifiers (shortcut recorders, ⌘-hold hints) see them as they would real ones.
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Command))
            if down {
                event.flags.formUnion(HyperTapState.flags)
            } else {
                // The event carries the four from the "down" above; the keyboard itself says which
                // of them are really still held.
                let real = CGEventSource.flagsState(.hidSystemState).intersection(HyperTapState.flags)
                event.flags = event.flags.subtracting(HyperTapState.flags).union(real)
            }
            return Unmanaged.passUnretained(event)
        }
        fallthrough
    default:
        if HyperTapState.held { event.flags.formUnion(HyperTapState.flags) }
        return Unmanaged.passUnretained(event)
    }
}
