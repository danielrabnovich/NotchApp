import AppKit
import Combine

/// Mouse and trackpad tweaks through an event tap (needs Accessibility access):
/// - reverse a mouse wheel's scrolling while leaving the trackpad's natural scrolling alone,
/// - turn a three-finger click on the trackpad into a middle click.
@MainActor
final class MouseUtilities {
    static let shared = MouseUtilities()

    private var scrollTap: (port: CFMachPort, source: CFRunLoopSource)?
    private var clickTap: (port: CFMachPort, source: CFRunLoopSource)?
    private var cancellables = Set<AnyCancellable>()
    private var retryTimer: Timer?

    func start() {
        let s = AppSettings.shared
        s.$reverseMouseScroll.combineLatest(s.$threeFingerMiddleClick)
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.reconfigure() } }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { _ in DispatchQueue.main.async { Multitouch.restart() } }
            .store(in: &cancellables)
    }

    private func reconfigure() {
        let s = AppSettings.shared
        MouseTapState.reverseScroll = s.reverseMouseScroll
        MouseTapState.middleClick = s.threeFingerMiddleClick
        MouseTapState.middleClickFingers = Self.systemThreeFingerDragEnabled() ? 4 : 3
        if s.threeFingerMiddleClick { Multitouch.start() } else { Multitouch.stop() }

        let wanted = s.reverseMouseScroll || s.threeFingerMiddleClick
        if wanted, scrollTap == nil, clickTap == nil { install() }
        if !wanted { uninstall() }
    }

    private static func systemThreeFingerDragEnabled() -> Bool {
        ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"].contains {
            (CFPreferencesCopyAppValue("TrackpadThreeFingerDrag" as CFString, $0 as CFString) as? NSNumber)?.boolValue ?? false
        }
    }

    private func install() {
        // Without Accessibility access the tap can't be created; retry once it's granted.
        guard AXIsProcessTrusted() else {
            retryTimer?.invalidate()
            let t = Timer(timeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    MouseUtilities.shared.retryTimer?.invalidate()
                    MouseUtilities.shared.retryTimer = nil
                    MouseUtilities.shared.reconfigure()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            retryTimer = t
            return
        }
        // The wheel is flipped at the HID level, before the window server derives pixel deltas
        // from its ticks. Clicks are rewritten at the session level, as the "Middle" utilities do.
        scrollTap = makeTap(.cghidEventTap, .tailAppendEventTap, [.scrollWheel])
        clickTap = makeTap(.cgSessionEventTap, .headInsertEventTap,
                           [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                            .rightMouseDown, .rightMouseUp, .rightMouseDragged])
        MouseTapState.taps = [scrollTap, clickTap].compactMap { $0?.port }
    }

    private func makeTap(_ location: CGEventTapLocation, _ place: CGEventTapPlacement,
                         _ types: [CGEventType]) -> (port: CFMachPort, source: CFRunLoopSource)? {
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: location, place: place, options: .defaultTap,
                                           eventsOfInterest: mask, callback: mouseTapCallback, userInfo: nil),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return nil }
        CFRunLoopAddSource(TapThread.runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return (port, source)
    }

    private func uninstall() {
        retryTimer?.invalidate()
        retryTimer = nil
        MouseTapState.taps = []
        for tap in [scrollTap, clickTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap.port, enable: false)
            CFRunLoopRemoveSource(TapThread.runLoop, tap.source, .commonModes)
            CFMachPortInvalidate(tap.port)
        }
        scrollTap = nil
        clickTap = nil
        MouseTapState.convertingClick = false
    }
}

/// The event taps' own thread. Every scroll and click on the Mac waits for a tap's callback; on the
/// main thread they queued behind the notch's drawing, which made swipes (everywhere) lag.
final class TapThread: Thread, @unchecked Sendable {
    nonisolated(unsafe) private static var loop: CFRunLoop?
    private static let ready = DispatchSemaphore(value: 0)
    private static let thread: TapThread = {
        let t = TapThread()
        t.name = "NotchApp event taps"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
        return t
    }()

    static var runLoop: CFRunLoop {
        _ = thread
        return loop!
    }

    override func main() {
        Self.loop = CFRunLoopGetCurrent()
        // A run loop with no sources returns at once; a port keeps this one waiting for the taps.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        Self.ready.signal()
        CFRunLoopRun()
    }
}

/// Read from the event tap callbacks (on the tap thread); written from the main thread.
enum MouseTapState {
    nonisolated(unsafe) static var reverseScroll = false
    nonisolated(unsafe) static var middleClick = false
    nonisolated(unsafe) static var taps: [CFMachPort] = []
    /// A left or right press that was turned into a middle press, so its drag and release follow.
    nonisolated(unsafe) static var convertingClick = false
    /// When the last converted click was released: tap-to-click sends a second click as the
    /// fingers lift, which would otherwise land as an ordinary click right after the middle one.
    nonisolated(unsafe) static var lastConvertedUp: TimeInterval = 0
    nonisolated(unsafe) static var swallowingClick = false
    /// macOS's three-finger drag owns three-finger touches, so the middle click moves to four.
    nonisolated(unsafe) static var middleClickFingers: Int32 = 3
    /// Uptime of the last scroll event with a gesture phase (only touch devices send those).
    nonisolated(unsafe) static var lastGesturePhase: TimeInterval = 0
}

private func mouseTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                              _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MouseTapState.taps.forEach { CGEvent.tapEnable(tap: $0, enable: true) }
    case .scrollWheel:
        if MouseTapState.reverseScroll, isMouseWheel(event) { reverse(event) }
    case .leftMouseDown, .rightMouseDown:
        guard MouseTapState.middleClick else { break }
        let now = ProcessInfo.processInfo.systemUptime
        // Only a real press counts: the fingers must be on the pad now and have settled there
        // (a click that lands with the last finger is a synthesized tap-to-click).
        guard Multitouch.fingerCount == MouseTapState.middleClickFingers,
              now - Multitouch.lastFrame <= 0.25, now - Multitouch.countSince >= 0.04 else { break }
        if now - MouseTapState.lastConvertedUp < 0.3 {
            MouseTapState.swallowingClick = true
            return nil
        }
        MouseTapState.convertingClick = true
        return Unmanaged.passUnretained(asMiddle(event, .otherMouseDown))
    case .leftMouseDragged, .rightMouseDragged:
        if MouseTapState.convertingClick { return Unmanaged.passUnretained(asMiddle(event, .otherMouseDragged)) }
        if MouseTapState.swallowingClick { return nil }
    case .leftMouseUp, .rightMouseUp:
        if MouseTapState.swallowingClick {
            MouseTapState.swallowingClick = false
            return nil
        }
        if MouseTapState.convertingClick {
            MouseTapState.convertingClick = false
            MouseTapState.lastConvertedUp = ProcessInfo.processInfo.systemUptime
            return Unmanaged.passUnretained(asMiddle(event, .otherMouseUp))
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

private func asMiddle(_ event: CGEvent, _ type: CGEventType) -> CGEvent {
    event.type = type
    event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    return event
}

/// Wheels send discrete steps. Some wheels (and mouse drivers) send continuous events too, but
/// never with a gesture phase; trackpads and the Magic Mouse always carry one.
private func isMouseWheel(_ event: CGEvent) -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    let phased = event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
        || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
    if phased { MouseTapState.lastGesturePhase = now }
    if event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 { return true }
    if phased { return false }
    // Trackpads can send a phaseless event between a gesture and its momentum; it still
    // carries the gesture's scroll count, and only follows a phased event closely.
    return event.getIntegerValueField(.scrollWheelEventScrollCount) == 0 || now - MouseTapState.lastGesturePhase > 1
}

/// Flips both axes. Every field is read before any is written: writing a line delta makes the
/// system rederive the point and fixed-point fields, so negating those afterwards undid the flip.
private func reverse(_ event: CGEvent) {
    let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    for (line, point, fixed) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1, CGEventField.scrollWheelEventFixedPtDeltaAxis1),
                                 (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2)] {
        let l = event.getIntegerValueField(line)
        let p = event.getIntegerValueField(point)
        let f = event.getDoubleValueField(fixed)
        guard l != 0 || p != 0 || f != 0 else { continue }
        event.setIntegerValueField(line, value: -l)
        // A discrete tick's other fields follow from its line; a zero line can't carry a
        // high-resolution tick, and continuous events need them written outright.
        if continuous || l == 0 {
            event.setIntegerValueField(point, value: -p)
            event.setDoubleValueField(fixed, value: -f)
        }
    }
}

/// Counts fingers on the trackpad through the private MultitouchSupport framework
/// (the same approach the "Middle" utilities use).
enum Multitouch {
    private typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    nonisolated(unsafe) private static var devices: [UnsafeMutableRawPointer] = []
    /// Keeps the devices alive while their callbacks are registered.
    nonisolated(unsafe) private static var deviceArray: CFArray?
    nonisolated(unsafe) private(set) static var fingerCount: Int32 = 0
    /// Uptime of the latest contact frame; frames stream only while fingers touch the pad.
    nonisolated(unsafe) private(set) static var lastFrame: TimeInterval = 0
    /// Uptime when the finger count last changed.
    nonisolated(unsafe) private(set) static var countSince: TimeInterval = 0

    // Runs on the multitouch thread; the word-sized writes are read on the main thread.
    private static let callback: Callback = { _, _, count, _, _ in
        let now = ProcessInfo.processInfo.systemUptime
        if count != Multitouch.fingerCount { Multitouch.countSince = now }
        Multitouch.fingerCount = count
        Multitouch.lastFrame = now
        return 0
    }

    static func start() {
        guard devices.isEmpty, let handle,
              let listSym = dlsym(handle, "MTDeviceCreateList"),
              let regSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart") else { return }
        let list = unsafeBitCast(listSym, to: DeviceList.self)
        let register = unsafeBitCast(regSym, to: Register.self)
        let startDevice = unsafeBitCast(startSym, to: Start.self)
        guard let array = list()?.takeRetainedValue() else { return }
        deviceArray = array
        for i in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, callback)
            _ = startDevice(device, 0)
            devices.append(device)
        }
    }

    static func stop() {
        guard let handle, let stopSym = dlsym(handle, "MTDeviceStop") else { devices = []; deviceArray = nil; return }
        let stopDevice = unsafeBitCast(stopSym, to: Stop.self)
        devices.forEach { _ = stopDevice($0) }
        devices = []
        deviceArray = nil
        fingerCount = 0
    }

    /// Devices stop reporting after sleep, so start them again on wake.
    static func restart() {
        guard !devices.isEmpty else { return }
        stop()
        start()
    }
}
