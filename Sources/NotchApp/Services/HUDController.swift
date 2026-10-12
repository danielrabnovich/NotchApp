import AppKit
import ApplicationServices
import Combine

/// Replaces the system volume / brightness overlay with the notch HUD.
///
/// With Accessibility permission we intercept the media keys (so Apple's HUD never
/// appears) and set volume/brightness ourselves. Without it we fall back to observing
/// changes and showing our HUD alongside Apple's.
@MainActor
final class HUDController {
    static let shared = HUDController()

    private let tap = MediaKeyTap()
    private(set) var tapActive = false
    private var permissionTimer: Timer?
    private var brightnessTimer: Timer?
    private var lastBrightness: Float?
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    // NX_KEYTYPE_* constants from IOKit/hidsystem/ev_keymap.h
    private enum Key: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    func start() {
        tap.handler = { [weak self] key, isDown, flags in
            MainActor.assumeIsolated { self?.handle(keyCode: key, isDown: isDown, flags: flags) ?? false }
        }
        tap.onDisabled = { [weak self] in
            MainActor.assumeIsolated {
                self?.tapActive = false
                self?.ensureTap()
            }
        }

        AudioOutputManager.shared.onVolumeChange = { [weak self] in
            guard let self, !self.tapActive, self.settings.volumeHUD else { return }
            self.showVolume()
        }

        settings.$volumeHUD.combineLatest(settings.$brightnessHUD)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.ensureTap() } }
            .store(in: &cancellables)
    }

    var hasAccessibility: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func ensureTap() {
        let wanted = settings.volumeHUD || settings.brightnessHUD
        if !wanted {
            tap.stop()
            tapActive = false
            permissionTimer?.invalidate()
            permissionTimer = nil
            updateBrightnessFallback()
            return
        }
        if !tapActive {
            if AXIsProcessTrusted() {
                tapActive = tap.start()
            } else if permissionTimer == nil {
                requestAccessibility()
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                    MainActor.assumeIsolated {
                        guard let self else { return t.invalidate() }
                        if AXIsProcessTrusted() {
                            t.invalidate()
                            self.permissionTimer = nil
                            self.ensureTap()
                        }
                    }
                }
            }
        }
        updateBrightnessFallback()
    }

    /// Without the event tap we can only notice brightness changes by polling.
    private func updateBrightnessFallback() {
        let needed = settings.brightnessHUD && !tapActive && Brightness.isAvailable
        if needed, brightnessTimer == nil {
            lastBrightness = Brightness.get()
            brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let b = Brightness.get() else { return }
                    if let last = self.lastBrightness, abs(last - b) > 0.004 {
                        ActivityCenter.shared.show(.brightness(level: b), for: 1.6)
                    }
                    self.lastBrightness = b
                }
            }
        } else if !needed {
            brightnessTimer?.invalidate()
            brightnessTimer = nil
        }
    }

    /// Returns true when the key event was handled and should be swallowed.
    private func handle(keyCode: Int, isDown: Bool, flags: NSEvent.ModifierFlags) -> Bool {
        guard let key = Key(rawValue: keyCode) else { return false }
        let fine = flags.contains(.shift) && flags.contains(.option)
        // Option alone opens the related System Settings pane – let macOS do that.
        if flags.contains(.option), !flags.contains(.shift) { return false }
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16

        switch key {
        case .soundUp, .soundDown, .mute:
            guard settings.volumeHUD, AudioOutputManager.canSetVolume else { return false }
            guard isDown else { return true }
            switch key {
            case .mute:
                AudioOutputManager.isMuted.toggle()
            case .soundUp:
                AudioOutputManager.isMuted = false
                AudioOutputManager.volume = AudioOutputManager.volume + step
            default:
                let v = AudioOutputManager.volume - step
                AudioOutputManager.volume = v
                if v <= 0.001 { AudioOutputManager.isMuted = true }
            }
            showVolume()
            return true

        case .brightnessUp, .brightnessDown:
            guard settings.brightnessHUD, Brightness.isAvailable, let current = Brightness.get() else { return false }
            guard isDown else { return true }
            let target = min(1, max(0, current + (key == .brightnessUp ? step : -step)))
            Brightness.set(target)
            ActivityCenter.shared.show(.brightness(level: target), for: 1.6)
            return true
        }
    }

    /// Set while the volume is being scrolled on the Duo Glance: its dots show the level, and a
    /// Flash would cover the very Glance being scrolled.
    static var quietUntil = Date.distantPast

    private func showVolume() {
        guard Date() > Self.quietUntil else { return }
        let muted = AudioOutputManager.isMuted
        ActivityCenter.shared.show(.volume(level: muted ? 0 : AudioOutputManager.volume, muted: muted), for: 1.6)
    }
}

// MARK: - Event tap

/// CGEventTap for NX_SYSDEFINED media-key events.
final class MediaKeyTap {
    var handler: ((Int, Bool, NSEvent.ModifierFlags) -> Bool)?
    var onDisabled: (() -> Void)?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    func start() -> Bool {
        stop()
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: mediaKeyCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.port = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }

    fileprivate func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) } else { onDisabled?() }
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let data1 = ns.data1
    let keyCode = (data1 & 0xFFFF_0000) >> 16
    let keyFlags = data1 & 0x0000_FFFF
    let isDown = ((keyFlags & 0xFF00) >> 8) == 0xA
    let consumed = tap.handler?(keyCode, isDown, ns.modifierFlags) ?? false
    return consumed ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Built-in display brightness (private DisplayServices)

enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

    static var builtinDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var isAvailable: Bool { getFn != nil && setFn != nil && builtinDisplay != nil }

    static func get() -> Float? {
        guard let getFn, let id = builtinDisplay else { return nil }
        var value: Float = 0
        return getFn(id, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let setFn, let id = builtinDisplay else { return }
        _ = setFn(id, value)
    }
}
