import AVFoundation
import CoreAudio
import Speech

/// Speech turned into text on this Mac (Apple's SpeechAnalyzer, macOS 26+), from two places: what
/// the Mac is playing (a call's other side, a video), through a listen-only Core Audio tap, and the
/// microphone (you). Each source has its own transcriber, so a transcript knows who's who without
/// guessing at voices.

/// One stream of audio into one transcriber. Buffers arrive in any format; they're converted to
/// the transcriber's own on a serial queue.
@available(macOS 26, *)
final class SpeechStream: @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private let queue = DispatchQueue(label: "com.notchapp.speech", qos: .userInitiated)
    private var results: Task<Void, Never>?

    /// `onText`: the text so far of what's being said (volatile), or a finished stretch (final).
    static func make(onText: @escaping @Sendable (String, _ final: Bool) -> Void) async throws -> SpeechStream {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        // The language's model downloads once (macOS keeps it).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "NotchApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech isn't available for this language"])
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        let s = SpeechStream(transcriber: transcriber, analyzer: analyzer, input: continuation, format: format)
        s.results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    onText(text, result.isFinal)
                }
            } catch {}
        }
        return s
    }

    private init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.input = input
        self.format = format
    }

    /// Audio in, any format. The buffer is converted on the stream's own queue.
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter else { return }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
        }
    }

    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        results?.cancel()
    }
}

/// What the Mac is playing, as audio buffers: a listen-only process tap on every app's output
/// (nothing is muted or rerouted), as the visualizer uses.
final class SystemAudioSource {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private static let queue = DispatchQueue(label: "com.notchapp.systemaudio", qos: .userInitiated)

    init?(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "NotchApp Captions"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != kAudioObjectUnknown else { return nil }

        var formatAddr = Self.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &asbdSize, &asbd) == noErr,
              let format = AVAudioFormat(streamDescription: &asbd) else { invalidate(); return nil }

        var uidAddr = Self.address(kAudioTapPropertyUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &size, &uid) == noErr,
              let tapUID = uid?.takeRetainedValue() as String?, let outputUID = Self.defaultOutputUID else { invalidate(); return nil }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchApp Captions",
            kAudioAggregateDeviceUIDKey: "com.notchapp.captions.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { invalidate(); return nil }

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, Self.queue) { _, input, _, output, _ in
            // The tap's buffers last only for this call: copied out.
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if let first = list.first, first.mDataByteSize > 0, asbd.mBytesPerFrame > 0 {
                let frames = AVAudioFrameCount(first.mDataByteSize / asbd.mBytesPerFrame)
                if let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                    copy.frameLength = frames
                    let dest = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                    for (i, source) in list.enumerated() where i < dest.count {
                        if let from = source.mData, let to = dest[i].mData {
                            memcpy(to, from, Int(min(source.mDataByteSize, dest[i].mDataByteSize)))
                        }
                    }
                    onBuffer(copy)
                }
            }
            for buffer in UnsafeMutableAudioBufferListPointer(output) { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
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

/// The microphone, as audio buffers.
final class MicSource {
    private let engine = AVAudioEngine()

    init?(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in onBuffer(buffer) }
        do { try engine.start() } catch { node.removeTap(onBus: 0); return nil }
    }

    func invalidate() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit { invalidate() }
}
