import AppKit
import Combine
import AudioToolbox
import CoreAudio

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    /// Apple's Bluetooth product ID, from the Bluetooth device of the same name: which AirPods or
    /// Beats these are, for their own symbol.
    var productID: Int? = nil

    var icon: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            let n = name.lowercased()
            if productID != nil || n.contains("airpods") || n.contains("beats") {
                return DeviceBatteries.Device.headphoneSymbol(productID: productID, name: n)
            }
            if n.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return name.lowercased().contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB:
            return "cable.connector"
        default:
            return "hifispeaker"
        }
    }
}

/// Lists audio outputs, switches the default output, and reads/writes system volume.
@MainActor
final class AudioOutputManager: ObservableObject {
    static let shared = AudioOutputManager()

    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var currentID: AudioDeviceID = 0

    /// The default output's volume and mute, kept current for what draws them (the Duo Glance).
    @Published private(set) var level: Float = 0
    @Published private(set) var muted = false

    /// Called when the default device's volume changes (from anywhere).
    var onVolumeChange: (() -> Void)?

    private var volumeListenerDevice: AudioDeviceID = 0
    private var cancellables = Set<AnyCancellable>()
    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async {
            self?.readVolume()
            self?.onVolumeChange?()
        }
    }

    var current: AudioOutputDevice? { devices.first { $0.id == currentID } }

    func start() {
        refresh()
        var devicesAddr = Self.address(kAudioHardwarePropertyDevices)
        var defaultAddr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, .main, block)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, .main, block)
        // The Bluetooth list says which model each pair of headphones is; it can arrive later.
        DeviceBatteries.shared.$devices.dropFirst().sink { _ in DispatchQueue.main.async { AudioOutputManager.shared.refresh() } }
            .store(in: &cancellables)
    }

    func refresh() {
        var addr = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return }

        devices = ids.compactMap { id in
            guard Self.hasOutput(id), let name = Self.name(of: id) else { return nil }
            let transport: UInt32 = Self.property(id, kAudioDevicePropertyTransportType) ?? 0
            if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual { return nil }
            let model = DeviceBatteries.shared.devices.first { $0.productID != nil && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return AudioOutputDevice(id: id, name: name, transport: transport, productID: model?.productID)
        }
        currentID = Self.defaultOutput
        attachVolumeListener()
        readVolume()
    }

    private func readVolume() {
        let (v, m) = (Self.volume, Self.isMuted)
        if v != level { level = v }
        if m != muted { muted = m }
    }

    func select(_ device: AudioOutputDevice) {
        var id = device.id
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var addr = Self.address(selector)
            AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        }
        currentID = device.id
    }

    private func attachVolumeListener() {
        let id = Self.defaultOutput
        guard id != volumeListenerDevice else { return }
        if volumeListenerDevice != 0 {
            for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
                var addr = Self.address(sel, scope: kAudioDevicePropertyScopeOutput)
                AudioObjectRemovePropertyListenerBlock(volumeListenerDevice, &addr, .main, volumeListener)
            }
        }
        volumeListenerDevice = id
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var addr = Self.address(sel, scope: kAudioDevicePropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(id, &addr, .main, volumeListener)
        }
    }

    // MARK: - Volume

    static var volume: Float {
        get { property(defaultOutput, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput) ?? 0 }
        set {
            var v = min(max(newValue, 0), 1)
            var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
            AudioObjectSetPropertyData(defaultOutput, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
        }
    }

    static var isMuted: Bool {
        get { (property(defaultOutput, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) as UInt32?) == 1 }
        set {
            var v: UInt32 = newValue ? 1 : 0
            var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
            AudioObjectSetPropertyData(defaultOutput, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        }
    }

    static var canSetVolume: Bool {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(defaultOutput, &addr),
              AudioObjectIsPropertySettable(defaultOutput, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    // MARK: - CoreAudio helpers

    static var defaultOutput: AudioDeviceID {
        property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr) == noErr else { return nil }
        return ptr.pointee
    }

    static func name(of id: AudioObjectID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static func hasOutput(_ id: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }
}
