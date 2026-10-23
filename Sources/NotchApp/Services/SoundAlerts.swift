import AVFoundation
import CoreAudio
import SoundAnalysis

/// Sounds around you, while headphones keep you from hearing them: a doorbell, a knock, a smoke
/// alarm, a baby, a dog, a siren, a phone. macOS's own sound recognition listens to the microphone
/// on this Mac (nothing is recorded or kept), and only while headphones are the output and Sound
/// alerts is on (Settings → Tools). The mic's orange dot shows meanwhile.
@MainActor
final class SoundAlerts {
    static let shared = SoundAlerts()

    /// The classifier's names for the sounds worth a Banner, and how to say them.
    private static let watched: [String: (title: String, icon: String)] = [
        "door_bell": ("Doorbell", "bell.fill"), "knock": ("Someone's knocking", "door.left.hand.closed"),
        // Most doorbells are chimes, which the classifier calls a bell (sometimes a telephone).
        "bell": ("A bell or chime", "bell.fill"),
        "smoke_detector": ("Smoke alarm", "smoke.fill"), "alarm_clock": ("An alarm", "alarm.fill"),
        "baby_crying": ("A baby's crying", "figure.and.child.holdinghands"), "crying_sobbing": ("Someone's crying", "person.wave.2.fill"),
        "dog_bark": ("A dog's barking", "dog.fill"), "siren": ("A siren", "light.beacon.max.fill"),
        "police_siren": ("A siren", "light.beacon.max.fill"), "ambulance_siren": ("A siren", "light.beacon.max.fill"),
        "fire_engine_siren": ("A siren", "light.beacon.max.fill"), "telephone_bell_ringing": ("A phone's ringing", "phone.fill"),
        "ringtone": ("A phone's ringing", "phone.fill"), "glass_breaking": ("Glass breaking", "exclamationmark.triangle.fill"),
        "shout": ("Someone's calling out", "person.wave.2.fill"), "screaming": ("Someone screamed", "exclamationmark.triangle.fill"),
    ]

    /// How sure the classifier has to be. Short sounds in a room (a chime through a door, a knock)
    /// rarely score high, so they need less; voices and dogs need more, to stay quiet otherwise.
    fileprivate nonisolated static func threshold(_ identifier: String) -> Double {
        ["door_bell", "bell", "knock", "smoke_detector", "alarm_clock", "telephone_bell_ringing", "ringtone"].contains(identifier) ? 0.55 : 0.7
    }

    private var engine: AVAudioEngine?
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: Observer?
    private var changes: NSObjectProtocol?
    private let queue = DispatchQueue(label: "com.notchapp.sounds", qos: .utility)
    private var lastAlert: [String: Date] = [:]
    private var cancellables: [Any] = []

    func start() {
        cancellables.append(AppSettings.shared.$toolsEnabled.sink { _ in DispatchQueue.main.async { SoundAlerts.shared.reconcile() } })
        cancellables.append(AppSettings.shared.$soundAlerts.sink { _ in DispatchQueue.main.async { SoundAlerts.shared.reconcile() } })
        // Headphones connecting switch the mic too: wait for that to settle, or the tap's format no
        // longer matches the hardware's and AVAudioEngine throws (an exception Swift can't catch).
        cancellables.append(AudioOutputManager.shared.$currentID.sink { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SoundAlerts.shared.reconcile() }
        })
    }

    /// Headphones on: Bluetooth ones, or a pair in the headphone jack.
    private var wearingHeadphones: Bool {
        guard let device = AudioOutputManager.shared.current else { return false }
        if device.transport == kAudioDeviceTransportTypeBluetooth || device.transport == kAudioDeviceTransportTypeBluetoothLE {
            return device.icon.contains("airpods") || device.icon.contains("headphones") || device.icon.contains("beats")
        }
        return device.transport == kAudioDeviceTransportTypeBuiltIn && device.name.lowercased().contains("headphone")
    }

    /// For notchdebug: listen as if headphones were on (to test with the speakers).
    var debugAnyOutput = false

    func reconcile() {
        let wanted = AppSettings.shared.soundAlerts && AppSettings.shared.toolsEnabled && (wearingHeadphones || debugAnyOutput)
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if wanted, engine == nil { listen() } else if !wanted, engine != nil { stop() }
    }

    private func listen() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let format = input.tappableFormat, let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return }
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = Observer()
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return }
        let queue = self.queue
        input.installTap(onBus: 0, bufferSize: 8192, format: format) { buffer, time in
            queue.async { analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime) }
        }
        do { try engine.start() } catch { input.removeTap(onBus: 0); DebugHooks.log("SoundAlerts: mic didn't start: \(error)"); return }
        DebugHooks.log("SoundAlerts: listening (\(AudioOutputManager.shared.current?.name ?? "?"))")
        // The mic changed under the engine (it stops itself): listen again on the new one.
        changes = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                         queue: .main) { _ in
            MainActor.assumeIsolated {
                SoundAlerts.shared.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SoundAlerts.shared.reconcile() }
            }
        }
        self.engine = engine
        self.analyzer = analyzer
        self.observer = observer
    }

    private func stop() {
        DebugHooks.log("SoundAlerts: stopped listening")
        if let changes { NotificationCenter.default.removeObserver(changes) }
        changes = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        analyzer = nil
        observer = nil
    }

    fileprivate func heard(_ identifier: String) {
        guard let sound = Self.watched[identifier] else { return }
        // Once a minute per kind of sound: a dog barks more than once.
        if let last = lastAlert[sound.title], Date().timeIntervalSince(last) < 60 { return }
        lastAlert[sound.title] = Date()
        ActivityCenter.shared.show(.notice(title: sound.title, detail: "Heard nearby while you've got headphones on",
                                           icon: sound.icon, tone: .info), for: 5)
    }

    private final class Observer: NSObject, SNResultsObserving {
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            // Among the three likeliest: a doorbell often comes second to "music" or "tuning fork".
            let likely = result.classifications.prefix(3)
            guard let top = likely.first(where: { SoundAlerts.watched[$0.identifier] != nil && $0.confidence >= SoundAlerts.threshold($0.identifier) })
            else { return }
            let id = top.identifier
            DebugHooks.log("SoundAlerts: heard \(likely.map { "\($0.identifier) \(String(format: "%.2f", $0.confidence))" })")
            DispatchQueue.main.async { MainActor.assumeIsolated { SoundAlerts.shared.heard(id) } }
        }
    }
}
