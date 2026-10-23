import AVFoundation
import CoreAudio
import Speech

/// Speech turned into text on this Mac (Apple's SpeechAnalyzer, macOS 26+), from two places: what
/// the Mac is playing (a call's other side, a video), through a listen-only Core Audio tap, and the
/// microphone (you). Each source has its own transcriber, so a transcript knows who's who without
/// guessing at voices.

// SpeechAnalyzer is in the macOS 26 SDK (Swift 6.2).
#if compiler(>=6.2)
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
    /// When the first buffer came in: the transcriber's clock starts there.
    private var firstInput: Date?
    private let lock = NSLock()

    /// `onText`: the text so far of what's being said (volatile), or a finished stretch (final),
    /// with when it began. `context`: names and words to listen for (people, projects).
    static func make(context: [String] = [], onText: @escaping @Sendable (String, _ final: Bool, _ began: Date?) -> Void) async throws -> SpeechStream {
        let transcriber = try await transcriber(volatile: true)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await listen(for: context, in: analyzer)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "NotchApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech isn't available for this language"])
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        let s = SpeechStream(transcriber: transcriber, analyzer: analyzer, input: continuation, format: format)
        s.results = Task { [weak s] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    onText(text, result.isFinal, s?.began(result.range.start))
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

    /// The transcriber for the Mac's language; its model downloads once (macOS keeps it).
    private static func transcriber(volatile: Bool) async throws -> SpeechTranscriber {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: volatile ? [.volatileResults] : [],
                                            attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    /// Names it should expect (the people on the call, the user, projects): heard right more often.
    private static func listen(for words: [String], in analyzer: SpeechAnalyzer) async {
        guard !words.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = words
        try? await analyzer.setContext(context)
    }

    private func began(_ time: CMTime) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let firstInput, time.isNumeric else { return nil }
        return firstInput.addingTimeInterval(time.seconds)
    }

    /// Audio in, any format. The buffer is converted on the stream's own queue.
    func append(_ buffer: AVAudioPCMBuffer) {
        let arrived = Date()
        queue.async { [self] in
            lock.lock()
            if firstInput == nil {
                firstInput = arrived.addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate)
            }
            lock.unlock()
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

    /// A recorded track, start to end, finished results only (steadier than the live stream's):
    /// each stretch of speech with where it starts and ends in the file, in seconds.
    static func transcribe(file url: URL, context: [String] = [],
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [(start: Double, end: Double, text: String)] {
        let audio = try AVAudioFile(forReading: url)
        let duration = max(1, Double(audio.length) / audio.processingFormat.sampleRate)
        let transcriber = try await transcriber(volatile: false)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await listen(for: context, in: analyzer)
        let collect = Task {
            var out: [(start: Double, end: Double, text: String)] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = result.range.start.seconds, end = result.range.end.seconds
                if !text.isEmpty, start.isFinite { out.append((start, end.isFinite ? end : start, text)) }
                if end.isFinite { progress(min(1, end / duration)) }
            }
            return out
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collect.cancel()
            throw error
        }
        let lines = try await collect.value
        progress(1)
        return lines
    }
}

#else
/// Built with an SDK older than macOS 26 (Command Line Tools on macOS 15): SpeechAnalyzer isn't
/// there to compile against, so speech features say they're unavailable.
@available(macOS 26, *)
final class SpeechStream: @unchecked Sendable {
    private static var unavailable: NSError {
        NSError(domain: "NotchApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech needs a build made with the macOS 26 SDK"])
    }
    static func make(context: [String] = [], onText: @escaping @Sendable (String, _ final: Bool, _ began: Date?) -> Void) async throws -> SpeechStream {
        throw unavailable
    }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async {}
    static func transcribe(file url: URL, context: [String] = [],
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [(start: Double, end: Double, text: String)] {
        throw unavailable
    }
}
#endif

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
        guard let format = node.tappableFormat else { return nil }
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in onBuffer(buffer) }
        do { try engine.start() } catch { node.removeTap(onBus: 0); return nil }
    }

    func invalidate() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit { invalidate() }
}

extension AVAudioInputNode {
    /// The format to tap the mic in, if it's settled: while the input device is switching (headphones
    /// connecting), the node's format can disagree with the hardware's, or have no channels, and
    /// installTap then throws an Objective-C exception, which crashes the app.
    var tappableFormat: AVAudioFormat? {
        let format = outputFormat(forBus: 0), hardware = inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              format.sampleRate == hardware.sampleRate, format.channelCount == hardware.channelCount else { return nil }
        return format
    }
}
