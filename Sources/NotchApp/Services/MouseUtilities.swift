import AppKit
import Combine

/// Mouse and trackpad tweaks through an event tap (needs Accessibility access):
/// - reverse a mouse wheel's scrolling while leaving the trackpad's natural scrolling alone,
/// - turn a three-finger click on the trackpad into a middle click.
@MainActor
final class MouseUtilities {
    static let shared = MouseUtilities()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
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
        if s.threeFingerMiddleClick { Multitouch.start() } else { Multitouch.stop() }

        let wanted = s.reverseMouseScroll || s.threeFingerMiddleClick
        if wanted, tap == nil { install() }
        if !wanted { uninstall() }
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
        let types: [CGEventType] = [.scrollWheel, .leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mouseTapCallback, userInfo: nil) else { return }
        MouseTapState.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    private func uninstall() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        MouseTapState.tap = nil
    }
}

/// Read from the event tap callback (main run loop).
enum MouseTapState {
    nonisolated(unsafe) static var reverseScroll = false
    nonisolated(unsafe) static var middleClick = false
    nonisolated(unsafe) static var tap: CFMachPort?
    /// A left-button press that was turned into a middle press, so its drag and release follow.
    nonisolated(unsafe) static var convertingClick = false
}

private func mouseTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                              _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = MouseTapState.tap { CGEvent.tapEnable(tap: tap, enable: true) }
    case .scrollWheel:
        // Wheels send discrete steps; trackpads and Magic Mouse send continuous gestures.
        if MouseTapState.reverseScroll, event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
            for (delta, point, fixed) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1, CGEventField.scrollWheelEventFixedPtDeltaAxis1),
                                          (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2)] {
                event.setIntegerValueField(delta, value: -event.getIntegerValueField(delta))
                event.setIntegerValueField(point, value: -event.getIntegerValueField(point))
                event.setDoubleValueField(fixed, value: -event.getDoubleValueField(fixed))
            }
        }
    case .leftMouseDown:
        if MouseTapState.middleClick, Multitouch.fingerCount == 3 {
            MouseTapState.convertingClick = true
            event.type = .otherMouseDown
            event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        }
    case .leftMouseDragged:
        if MouseTapState.convertingClick {
            event.type = .otherMouseDragged
            event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        }
    case .leftMouseUp:
        if MouseTapState.convertingClick {
            MouseTapState.convertingClick = false
            event.type = .otherMouseUp
            event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
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

    private static let callback: Callback = { _, _, count, _, _ in
        Multitouch.fingerCount = count
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
