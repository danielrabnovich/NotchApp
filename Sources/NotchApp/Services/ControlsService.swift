import AppKit
import CoreAudio
import CoreWLAN

/// Quick system toggles and actions for the Controls tab.
@MainActor
final class ControlsService: ObservableObject {
    static let shared = ControlsService()

    @Published private(set) var wifiOn = false
    @Published private(set) var darkMode = false
    @Published private(set) var micMuted = false
    @Published var volume: Float = 0
    @Published var brightness: Float = 0
    /// Empty Trash needs a second click within a few seconds.
    @Published private(set) var confirmingTrash = false
    @Published private(set) var lastError: String?

    private var micRestoreVolume: Float?

    func refresh() {
        wifiOn = CWWiFiClient.shared().interface()?.powerOn() ?? false
        darkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            || NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        micMuted = Self.inputMuted
        volume = AudioOutputManager.volume
        brightness = Brightness.get() ?? 0
    }

    // MARK: - Sliders

    func setVolume(_ v: Float) {
        volume = v
        AudioOutputManager.volume = v
        if v > 0, AudioOutputManager.isMuted { AudioOutputManager.isMuted = false }
    }

    func setBrightness(_ v: Float) {
        brightness = v
        Brightness.set(v)
    }

    // MARK: - Toggles

    func toggleWiFi() {
        guard let iface = CWWiFiClient.shared().interface() else { return }
        do {
            try iface.setPower(!iface.powerOn())
        } catch {
            lastError = "Couldn't change Wi-Fi"
        }
        wifiOn = iface.powerOn()
    }

    /// Switches the system appearance (macOS asks once to let NotchApp control System Events).
    func toggleDarkMode() {
        let target = !darkMode
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(target)"
        runAppleScript(script) { [weak self] ok in
            if ok { self?.darkMode = target } else { self?.lastError = "Allow NotchApp to control System Events in Privacy & Security → Automation" }
        }
    }

    func toggleMic() {
        let device = Self.defaultInput
        guard device != 0 else { return }
        var addr = AudioOutputManager.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        if AudioObjectHasProperty(device, &addr) {
            var value: UInt32 = micMuted ? 0 : 1
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        } else {
            // No mute switch on this input: drop its volume to zero and restore it later.
            var vol = AudioOutputManager.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput)
            var level: Float = micMuted ? (micRestoreVolume ?? 0.75) : 0
            if !micMuted {
                var current: Float = 0
                var size = UInt32(MemoryLayout<Float>.size)
                AudioObjectGetPropertyData(device, &vol, 0, nil, &size, &current)
                micRestoreVolume = current
            }
            AudioObjectSetPropertyData(device, &vol, 0, nil, UInt32(MemoryLayout<Float>.size), &level)
        }
        micMuted = Self.inputMuted
    }

    // MARK: - Actions

    func screenshot() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"),
                                           configuration: .init())
    }

    /// Pick a colour anywhere on screen; its hex value is copied.
    func pickColor() {
        NSColorSampler().show { color in
            guard let color else { return }
            let hex = color.hexString
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            ActivityCenter.shared.show(.notice(title: "Copied \(hex)", detail: "Color picker", icon: "eyedropper"), for: 2.5)
        }
    }

    func lockScreen() {
        typealias Lock = @convention(c) () -> Void
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            unsafeBitCast(sym, to: Lock.self)()
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            try? p.run()
        }
    }

    /// First click arms it; a second click within three seconds empties the Trash.
    func emptyTrash() {
        guard confirmingTrash else {
            confirmingTrash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.confirmingTrash = false }
            return
        }
        confirmingTrash = false
        runAppleScript("tell application \"Finder\" to empty trash") { [weak self] ok in
            if !ok { self?.lastError = "Allow NotchApp to control Finder in Privacy & Security → Automation" }
        }
    }

    func clearError() { lastError = nil }

    // MARK: - Helpers

    private func runAppleScript(_ source: String, completion: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let ok = error == nil
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok) } }
        }
    }

    private static var defaultInput: AudioDeviceID {
        AudioOutputManager.property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) ?? 0
    }

    private static var inputMuted: Bool {
        let device = defaultInput
        guard device != 0 else { return false }
        if let mute: UInt32 = AudioOutputManager.property(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput) {
            return mute == 1
        }
        let vol: Float? = AudioOutputManager.property(device, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput)
        return (vol ?? 1) == 0
    }
}
