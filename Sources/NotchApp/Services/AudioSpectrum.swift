import Accelerate
import AudioToolbox
import Combine
import CoreAudio
import SwiftUI

/// Real levels for the music visualizer: listens to the now-playing app's audio through a Core
/// Audio process tap (the same kind the mixer uses, but listen-only: nothing is muted or rerouted)
/// and splits it into frequency bands, bass to treble. Runs only while a visualizer is on screen
/// and music is playing, and only with the System Audio Recording permission; otherwise the
/// visualizer falls back to its old animation.
@MainActor
final class AudioSpectrum: ObservableObject {
    static let shared = AudioSpectrum()
    static let bandCount = 6

    /// 0…1 per band, bass first. Smoothed: quick to rise, slower to fall.
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: bandCount)
    /// Real audio is coming in (if not, visualizers animate on their own).
    @Published private(set) var isLive = false

    private var viewers = 0
    private var tap: SpectrumTap?
    private var tapTarget: String?
    private var poll: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let analyzer = SpectrumAnalyzer(bands: AudioSpectrum.bandCount)

    func start() {
        let media = MediaController.shared
        let refresh: () -> Void = { [weak self] in DispatchQueue.main.async { self?.reconcile() } }
        media.$isPlaying.removeDuplicates().sink { _ in refresh() }.store(in: &cancellables)
        media.$bundleID.removeDuplicates().sink { _ in refresh() }.store(in: &cancellables)
        AudioOutputManager.shared.$currentID.removeDuplicates().sink { [weak self] _ in
            // A new output device needs a new tap on it.
            DispatchQueue.main.async { self?.teardown(); self?.reconcile() }
        }.store(in: &cancellables)
        AudioMixer.shared.$permission.removeDuplicates().sink { _ in refresh() }.store(in: &cancellables)
        AppSettings.shared.$showVisualizer.removeDuplicates().sink { _ in refresh() }.store(in: &cancellables)
    }

    func viewerAppeared() {
        viewers += 1
        if viewers == 1 { reconcile() }
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { reconcile() }
    }

    static var permitted: Bool { AudioCapturePermission.status() == .granted }

    private func reconcile() {
        let media = MediaController.shared
        let wanted = viewers > 0 && media.isPlaying && AppSettings.shared.showVisualizer && Self.permitted
        guard wanted else { teardown(); return }
        let target = media.bundleID ?? "*"
        if tap == nil || tapTarget != target {
            teardown()
            tap = SpectrumTap(processObjects: Self.processObjects(for: media.bundleID), analyzer: analyzer)
            tapTarget = target
            DebugHooks.log("AudioSpectrum: tap \(tap == nil ? "failed" : "started") for \(target)")
        }
        guard tap != nil, poll == nil else { return }
        // 30 frames a second is plenty for four to six bars.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { AudioSpectrum.shared.pull() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func teardown() {
        tap?.invalidate()
        tap = nil
        tapTarget = nil
        poll?.invalidate()
        poll = nil
        if isLive { isLive = false }
        levels = Array(repeating: 0, count: Self.bandCount)
    }

    private func pull() {
        let raw = analyzer.read()
        var next = levels
        for i in 0..<Self.bandCount {
            let target = CGFloat(raw[i])
            // Rise fast so beats land; fall slower so bars don't flicker.
            next[i] = target > next[i] ? next[i] + (target - next[i]) * 0.6 : next[i] + (target - next[i]) * 0.18
        }
        levels = next
        let live = analyzer.secondsSinceAudio < 1.5
        if live != isLive { isLive = live }
    }

    /// Audio process objects belonging to the app that's playing (its helpers included: Safari's
    /// audio comes from a WebKit process, Spotify's from a helper). Empty means "all system audio".
    private static func processObjects(for bundleID: String?) -> [AudioObjectID] {
        guard let bundleID else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioOutputManager.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.filter { object in
            guard let pid: pid_t = AudioOutputManager.property(object, kAudioProcessPropertyPID), pid > 0 else { return false }
            return AppIdentity.of(pid: AppIdentity.responsiblePID(for: pid)).bundleID == bundleID
        }.sorted()
    }
}

/// A listen-only tap feeding the analyzer from Core Audio's realtime thread.
final class SpectrumTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private static let queue = DispatchQueue(label: "com.notchapp.spectrum", qos: .userInteractive)

    init?(processObjects: [AudioObjectID], analyzer: SpectrumAnalyzer) {
        let description = processObjects.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "NotchApp Visualizer"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != kAudioObjectUnknown else { return nil }

        var addr = Self.address(kAudioTapPropertyUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &uid) == noErr,
              let tapUID = uid?.takeRetainedValue() as String?,
              let outputUID = Self.defaultOutputUID else { invalidate(); return nil }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchApp Visualizer",
            kAudioAggregateDeviceUIDKey: "com.notchapp.visualizer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { invalidate(); return nil }

        // Only reads the input; the output buffers are left silent, so nothing extra is heard.
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, Self.queue) { _, input, _, output, _ in
            analyzer.process(input)
            let outs = UnsafeMutableAudioBufferListPointer(output)
            for buffer in outs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
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

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static var defaultOutputUID: String? {
        var device = AudioDeviceID(0)
        var deviceAddr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddr, 0, nil, &deviceSize, &device) == noErr
        else { return nil }
        var addr = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

/// Turns audio into band levels. `process` runs on the realtime audio thread, so everything it
/// touches is allocated up front and nothing locks; the main thread reads the latest levels.
/// A torn read of a Float is harmless here (it's a bar height), and aligned Float writes are
/// atomic on Apple silicon and Intel.
final class SpectrumAnalyzer: @unchecked Sendable {
    private let size = 1024
    private let log2n: vDSP_Length = 10
    private let fft: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let ring: UnsafeMutablePointer<Float>
    private var ringIndex = 0
    private var filled = 0
    private let frame: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let bandCount: Int
    /// FFT bin ranges per band: log-spaced from ~40 Hz to ~12 kHz.
    private let edges: [Int]
    private let output: UnsafeMutablePointer<Float>
    /// Each band's recent loudest (dB), so quiet and loud songs both fill the bars.
    private let peaks: UnsafeMutablePointer<Float>
    private static let range: Float = 24
    private var lastAudio: UInt64 = 0
    private var sampleRate: Float = 48_000

    init(bands: Int) {
        bandCount = bands
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = .allocate(capacity: size); vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        ring = .allocate(capacity: size); ring.initialize(repeating: 0, count: size)
        frame = .allocate(capacity: size)
        real = .allocate(capacity: size / 2)
        imag = .allocate(capacity: size / 2)
        magnitudes = .allocate(capacity: size / 2)
        output = .allocate(capacity: bands); output.initialize(repeating: 0, count: bands)
        peaks = .allocate(capacity: bands); peaks.initialize(repeating: -80, count: bands)
        let low: Float = 40, high: Float = 12_000
        edges = (0...bands).map { i in
            let hz = low * pow(high / low, Float(i) / Float(bands))
            return max(1, min(Int(hz / 48_000 * Float(1024)), 1024 / 2 - 1))
        }
    }

    /// Latest band levels, 0…1.
    func read() -> [Float] { (0..<bandCount).map { output[$0] } }

    var secondsSinceAudio: Double {
        guard lastAudio > 0 else { return .infinity }
        return Double(mach_absolute_time() - lastAudio) * Self.ticksToSeconds
    }

    private static let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        // Non-interleaved stereo arrives as two buffers; average whatever is there into mono.
        let second = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        var loudest: Float = 0
        for f in 0..<frames {
            var v = samples[f * channels]
            if channels > 1 { v = (v + samples[f * channels + 1]) * 0.5 } else if let second { v = (v + second[f]) * 0.5 }
            ring[ringIndex] = v
            ringIndex = (ringIndex + 1) % size
            loudest = max(loudest, abs(v))
        }
        filled = min(filled + frames, size)
        if loudest > 1e-4 { lastAudio = mach_absolute_time() }
        guard filled == size else { return }
        analyze()
    }

    private func analyze() {
        // Oldest sample first, windowed.
        let tail = size - ringIndex
        frame.update(from: ring + ringIndex, count: tail)
        (frame + tail).update(from: ring, count: ringIndex)
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(size))

        var split = DSPSplitComplex(realp: real, imagp: imag)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
        }
        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(size / 2))

        for b in 0..<bandCount {
            let lo = edges[b], hi = max(edges[b + 1], lo + 1)
            var mean: Float = 0
            vDSP_meanv(magnitudes + lo, 1, &mean, vDSP_Length(hi - lo))
            // In decibels, against each band's recent peak (which slowly relaxes so a loud intro
            // doesn't flatten the rest): the top 24 dB fill the bar, so beats and gaps both show.
            let db = 20 * log10(max(mean, 1e-7))
            peaks[b] = max(db, peaks[b] - 0.04)
            let level = (db - (peaks[b] - Self.range)) / Self.range
            output[b] = min(max(level, 0), 1)
        }
    }
}
