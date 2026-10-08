import AppKit
import AudioToolbox
import CoreAudio

/// An app (with its helper processes) that is producing audio.
struct MixerApp: Identifiable, Equatable {
    /// Bundle ID where there is one; volumes are remembered under it.
    let id: String
    var name: String
    var bundlePath: String?
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
}

/// Per-app volume. macOS has no per-app volume control, so for each app that isn't at 100%
/// the mixer taps the app's audio (muting the original), scales it, and plays it back through
/// the current output device. Apps at 100% are left completely alone.
@MainActor
final class AudioMixer: ObservableObject {
    static let shared = AudioMixer()

    enum Permission { case unknown, granted, denied }

    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var permission: Permission = .unknown
    @Published private(set) var volumes: [String: Float] = [:]
    @Published private(set) var muted: Set<String> = []

    private var allGroups: [String: MixerApp] = [:]
    /// When each app was last heard, so faders don't vanish in the gap between songs.
    private var lastHeard: [String: Date] = [:]
    private var taps: [String: AppTap] = [:]
    private var gains: [String: GainBox] = [:]
    private var pollTimer: Timer?
    private var viewers = 0
    private var started = false
    private var enabled = false
    private let defaults = UserDefaults.standard

    /// Turning the mixer off puts every app back on its normal audio path.
    func setEnabled(_ on: Bool) {
        enabled = on
        if on { start() } else { stop() }
    }

    private func start() {
        guard !started else { refresh(); return }
        started = true
        volumes = (defaults.dictionary(forKey: "mixer.volumes") as? [String: Double] ?? [:]).mapValues { Float($0) }
        muted = Set(defaults.stringArray(forKey: "mixer.muted") ?? [])
        permission = AudioCapturePermission.status()

        let system = AudioObjectID(kAudioObjectSystemObject)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { AudioMixer.shared.refresh() } }
        }
        let outputBlock: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { AudioMixer.shared.rebuildAllTaps() } }
        }
        var processes = AudioOutputManager.address(kAudioHardwarePropertyProcessObjectList)
        var output = AudioOutputManager.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(system, &processes, .main, block)
        AudioObjectAddPropertyListenerBlock(system, &output, .main, outputBlock)
        refresh()
    }

    /// Restores every app's original audio path.
    func stop() {
        taps.values.forEach { $0.invalidate() }
        taps = [:]
    }

    func viewerAppeared() {
        viewers += 1
        guard pollTimer == nil else { return }
        refresh()
        // "Is playing" has no change notification per process, so poll while the mixer is visible.
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AudioMixer.shared.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - Volume

    func volume(for app: MixerApp) -> Float { volumes[app.id] ?? 1 }
    func isMuted(_ app: MixerApp) -> Bool { muted.contains(app.id) }

    func setVolume(_ value: Float, for app: MixerApp) {
        let v = min(1, max(0, value))
        if v >= 0.995 { volumes[app.id] = nil } else { volumes[app.id] = v }
        defaults.set(volumes.mapValues { Double($0) }, forKey: "mixer.volumes")
        apply(to: app.id)
    }

    func toggleMute(_ app: MixerApp) {
        if muted.contains(app.id) { muted.remove(app.id) } else { muted.insert(app.id) }
        defaults.set(Array(muted), forKey: "mixer.muted")
        apply(to: app.id)
    }

    func resetAll() {
        volumes = [:]
        muted = []
        defaults.removeObject(forKey: "mixer.volumes")
        defaults.removeObject(forKey: "mixer.muted")
        stop()
    }

    func requestPermission() {
        AudioCapturePermission.request { granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let mixer = AudioMixer.shared
                    mixer.permission = granted ? .granted : .denied
                    mixer.rebuildAllTaps()
                }
            }
        }
    }

    private func gain(for id: String) -> Float { muted.contains(id) ? 0 : (volumes[id] ?? 1) }

    /// Updates the live gain, creating or removing the tap as needed.
    private func apply(to id: String) {
        let g = gain(for: id)
        gains[id, default: GainBox()].value = g
        if g < 0.995 && permission != .granted {
            if permission == .unknown { requestPermission() }
            return
        }
        syncTap(for: id)
    }

    // MARK: - Processes and taps

    private func refresh() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioOutputManager.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var groups: [String: MixerApp] = [:]
        for object in objects {
            guard let pid: pid_t = AudioOutputManager.property(object, kAudioProcessPropertyPID), pid > 0 else { continue }
            let owner = AppIdentity.responsiblePID(for: pid)
            guard owner != ownPID, pid != ownPID else { continue }
            let identity = AppIdentity.of(pid: owner)
            let key = identity.bundleID ?? "pid:\(owner)"
            let playing = (AudioOutputManager.property(object, kAudioProcessPropertyIsRunningOutput) as UInt32?) == 1
            var app = groups[key] ?? MixerApp(id: key, name: identity.name, bundlePath: identity.bundlePath,
                                              processObjects: [], isPlaying: false)
            app.processObjects.append(object)
            app.isPlaying = app.isPlaying || playing
            groups[key] = app
        }
        for key in groups.keys { groups[key]?.processObjects.sort() }
        allGroups = groups

        // Show what's playing (or played in the last few seconds), plus anything with a custom level.
        let now = Date()
        for app in groups.values where app.isPlaying { lastHeard[app.id] = now }
        lastHeard = lastHeard.filter { groups[$0.key] != nil }
        let visible = groups.values.filter {
            $0.isPlaying || now.timeIntervalSince(lastHeard[$0.id] ?? .distantPast) < 15
                || volumes[$0.id] != nil || muted.contains($0.id)
        }
        let sorted = visible.sorted { $0.isPlaying != $1.isPlaying ? $0.isPlaying : $0.name < $1.name }
        if sorted != apps { apps = sorted }

        for key in Set(groups.keys).union(taps.keys) { syncTap(for: key) }
    }

    private func syncTap(for id: String) {
        let g = gain(for: id)
        let box = gains[id, default: GainBox()]
        gains[id] = box
        box.value = g
        guard enabled, g < 0.995, permission == .granted, let group = allGroups[id], !group.processObjects.isEmpty,
              let outputUID = Self.defaultOutputUID else {
            taps[id]?.invalidate()
            taps[id] = nil
            return
        }
        if let tap = taps[id], tap.processObjects == group.processObjects, tap.outputUID == outputUID { return }
        taps[id]?.invalidate()
        taps[id] = AppTap(processObjects: group.processObjects, outputUID: outputUID, gain: box)
    }

    private func rebuildAllTaps() {
        stop()
        refresh()
    }

    private static var defaultOutputUID: String? {
        let device = AudioOutputManager.defaultOutput
        var addr = AudioOutputManager.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

/// Gain shared with the realtime audio thread. A single aligned Float write is atomic on
/// Apple silicon and Intel, which is all the audio thread needs.
final class GainBox: @unchecked Sendable {
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    init() { storage.pointee = 1 }
    deinit { storage.deallocate() }
    var value: Float {
        get { storage.pointee }
        set { storage.pointee = newValue }
    }
    var pointer: UnsafeMutablePointer<Float> { storage }
}

/// One app's audio rerouted through a private aggregate device with a gain stage.
final class AppTap {
    let processObjects: [AudioObjectID]
    let outputUID: String
    private let gain: GainBox
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private static let queue = DispatchQueue(label: "com.notchapp.mixer", qos: .userInteractive)

    init?(processObjects: [AudioObjectID], outputUID: String, gain: GainBox) {
        self.processObjects = processObjects
        self.outputUID = outputUID
        self.gain = gain

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "NotchApp Mixer"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != kAudioObjectUnknown else { return nil }

        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &uid) == noErr,
              let tapUID = uid?.takeRetainedValue() as String? else { invalidate(); return nil }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchApp Mixer",
            kAudioAggregateDeviceUIDKey: "com.notchapp.mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { invalidate(); return nil }

        let gainPointer = gain.pointer
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, Self.queue) { _, input, _, output, _ in
            AppTap.render(input, output, gain: gainPointer.pointee)
        }
        guard status == noErr, AudioDeviceStart(aggregateID, procID) == noErr else { invalidate(); return nil }
    }

    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit { invalidate() }

    /// Copies the tapped audio to the output streams, scaled by `gain`. Runs on the realtime
    /// audio thread, so no allocation or locking. Handles interleaved and non-interleaved layouts.
    private static func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        var inChannels = 0
        for b in 0..<ins.count { inChannels += Int(ins[b].mNumberChannels) }

        var outBase = 0
        for ob in 0..<outs.count {
            let out = outs[ob]
            let outCh = Int(out.mNumberChannels)
            guard let outData = out.mData, outCh > 0 else { continue }
            defer { outBase += outCh }
            let o = outData.assumingMemoryBound(to: Float.self)
            let frames = Int(out.mDataByteSize) / (MemoryLayout<Float>.size * outCh)
            for c in 0..<outCh {
                // Stereo feeds the first two outputs; mono feeds both of them.
                let channel = outBase + c
                var src = channel < inChannels ? channel : (inChannels == 1 && channel < 2 ? 0 : -1)
                var b = 0
                while src >= 0, b < ins.count, src >= Int(ins[b].mNumberChannels) {
                    src -= Int(ins[b].mNumberChannels)
                    b += 1
                }
                guard src >= 0, b < ins.count, let inData = ins[b].mData, gain > 0 else {
                    for f in 0..<frames { o[f * outCh + c] = 0 }
                    continue
                }
                let inCh = Int(ins[b].mNumberChannels)
                let i = inData.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(ins[b].mDataByteSize) / (MemoryLayout<Float>.size * inCh))
                for f in 0..<n { o[f * outCh + c] = i[f * inCh + src] * gain }
                for f in n..<frames { o[f * outCh + c] = 0 }
            }
        }
    }
}

/// Wraps the private TCC calls for the "System Audio Recording" permission that taps need.
/// Without it a muted-when-tapped app would go silent, so the mixer never taps until granted.
enum AudioCapturePermission {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @convention(block) @escaping (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func status() -> AudioMixer.Permission {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(symbol, to: Preflight.self)
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { completion(false); return }
        let request = unsafeBitCast(symbol, to: Request.self)
        request(service, nil, completion)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }
}

