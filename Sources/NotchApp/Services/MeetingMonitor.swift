import AppKit
import CoreAudio
import EventKit
import SwiftUI

/// Meeting mode: notices a call (a call app or a browser using the microphone for a while), keeps a
/// timer and a mute button beside the notch while it lasts, and when it ends offers to jot notes
/// (in Ramble) or a follow-up task. Dictation apps using the microphone aren't calls. Core Audio's
/// notifications say when the microphone may have changed hands (see `MicWatcher`); nothing is
/// polled, apart from a slow backstop while a call is on.
@MainActor
final class MeetingMonitor: ObservableObject {
    static let shared = MeetingMonitor()

    struct Call: Equatable {
        let app: String
        let bundleID: String?
        let started: Date
        /// The calendar event it's probably for (on now, or starting within ten minutes).
        let event: String?
        /// The people invited to it.
        var attendees: [String] = []
        /// Kept going by hand (in person, or "Keep Recording" after the mic went quiet): it ends
        /// when it's stopped, not when the microphone does.
        var kept = false
        var title: String { event ?? (inPerson ? "Meeting" : "Call on \(app)") }
        /// A meeting in the room, not a call app.
        var inPerson: Bool { bundleID == nil }
    }

    @Published private(set) var call: Call?

    private var candidateSince: Date?
    private var quietSince: Date?
    private var startWork: DispatchWorkItem?
    private var endWork: DispatchWorkItem?
    private var endingPrompt: UUID?
    private var watcher: MicWatcher?
    private var backstop: Timer?
    private var cancellables: [Any] = []

    /// Twenty seconds on the mic is a call, not a voice message; fifteen off it (a reconnect,
    /// switching devices) before it's over.
    private static let startDelay: TimeInterval = 20
    private static let endDelay: TimeInterval = 15

    private static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime", "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "org.whispersystems.signal-desktop",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram", "com.skype.skype", "co.teamport.around",
        "com.loom.desktop", "com.riverside.desktop", "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    func start() {
        // Loaded now, so a call cut off by a crash is recovered at launch.
        _ = MeetingAssistant.shared
        cancellables.append(AppSettings.shared.$meetingMode.sink { on in
            DispatchQueue.main.async {
                let monitor = MeetingMonitor.shared
                if on {
                    if monitor.watcher == nil { monitor.watcher = MicWatcher { MeetingMonitor.shared.evaluate() } }
                    monitor.evaluate()
                } else {
                    monitor.watcher?.stop()
                    monitor.watcher = nil
                    monitor.end(prompt: false)
                }
            }
        })
    }

    /// The call app on the microphone now, if any.
    private var caller: PrivacyMonitor.UsingApp? {
        PrivacyMonitor.appsUsingMic().first { Self.callApps.contains($0.bundleID ?? "") }
    }

    private func evaluate() {
        guard AppSettings.shared.meetingMode else { return }
        DebugHooks.log("MEETING mic now: \(PrivacyMonitor.appsUsingMic().map(\.name))")
        if let caller {
            quietSince = nil
            endWork?.cancel()
            endWork = nil
            if let endingPrompt { NotchPresenter.shared.withdraw(endingPrompt); self.endingPrompt = nil }
            guard call == nil else { return }
            if candidateSince == nil { candidateSince = Date() }
            guard startWork == nil else { return }
            let work = DispatchWorkItem { MeetingMonitor.shared.confirmStart() }
            startWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.startDelay, execute: work)
            DebugHooks.log("MEETING \(caller.name) on the mic")
        } else {
            candidateSince = nil
            startWork?.cancel()
            startWork = nil
            guard let call, !call.kept, endWork == nil else { return }
            quietSince = Date()
            let work = DispatchWorkItem { MeetingMonitor.shared.end(prompt: true) }
            endWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.endDelay, execute: work)
            // Being recorded: say so, and let it carry on.
            if LiveCaptions.shared.recording {
                let prompt = Prompt(icon: "phone.down.fill", tint: .systemOrange, title: "Call ended?",
                                    detail: "Saving the recording in \(Int(Self.endDelay)) s",
                                    actions: [.init(title: "Save Now") { MeetingMonitor.shared.end(prompt: true) },
                                              .init(title: "Keep Recording", primary: true) { MeetingMonitor.shared.keepRecording() }],
                                    dismissTitle: nil)
                endingPrompt = prompt.id
                NotchPresenter.shared.offer(prompt, peekFor: Self.endDelay)
            }
            DebugHooks.log("MEETING mic quiet, ending in \(Self.endDelay) s")
        }
    }

    private func confirmStart() {
        startWork = nil
        guard call == nil, let since = candidateSince, let caller else { return }
        let event = Self.currentEvent()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            call = Call(app: caller.name, bundleID: caller.bundleID, started: since, event: event?.title, attendees: Self.attendees(event))
        }
        DebugHooks.log("MEETING call started on \(caller.name)")
        if let call { MeetingAssistant.shared.callStarted(call) }
        // A backstop for the one change Core Audio may not announce: the call app letting go of
        // the mic while it keeps playing sound, with the mic still open for someone else (the
        // recording). Only while a call is on.
        backstop?.invalidate()
        backstop = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingMonitor.shared.evaluate() }
        }
    }

    /// The microphone went quiet but the recording should go on: it's now ended by hand.
    private func keepRecording() {
        endWork?.cancel()
        endWork = nil
        quietSince = nil
        call?.kept = true
    }

    /// A meeting in the room, recorded on the microphone (no call app involved).
    func beginInPerson() {
        guard call == nil else { return }
        // Only an event with people in it (a "Work" block isn't the meeting).
        let event = Self.currentEvent().flatMap { $0.hasAttendees ? $0 : nil }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            call = Call(app: "In person", bundleID: nil, started: Date(), event: event?.title, attendees: Self.attendees(event), kept: true)
        }
    }

    /// Ends the call (or the in-person meeting) now.
    func endCall() { end(prompt: true) }

    private func end(prompt: Bool) {
        startWork?.cancel()
        startWork = nil
        endWork?.cancel()
        endWork = nil
        if let endingPrompt { NotchPresenter.shared.withdraw(endingPrompt); self.endingPrompt = nil }
        backstop?.invalidate()
        backstop = nil
        guard let call else { return }
        let endedAt = quietSince ?? Date()
        let minutes = Int(endedAt.timeIntervalSince(call.started) / 60)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self.call = nil }
        quietSince = nil
        candidateSince = nil
        // Recorded: its notes take the place of the usual prompt.
        if MeetingAssistant.shared.callEnded(call, at: endedAt) { return }
        guard prompt, minutes >= 2 else { return }
        NotchPresenter.shared.offer(Prompt(icon: "phone.down.fill", tint: .systemGreen,
                                           title: "\(call.title) ended",
                                           detail: "\(minutes) min. Anything to remember?",
                                           actions: [.init(title: "Ramble Notes", primary: true) {
                                                         let ramble = RambleStore.shared
                                                         let header = "Notes from \(call.title):"
                                                         if !ramble.text.contains(header) {
                                                             ramble.text = (ramble.text.isEmpty ? "" : ramble.text + "\n\n") + header + "\n"
                                                         }
                                                         ramble.open()
                                                     },
                                                     .init(title: "Follow-up Task") {
                                                         TaskStore.shared.add(title: "Follow up: \(call.title)")
                                                         ActivityCenter.shared.show(.notice(title: "Added a follow-up", detail: call.title,
                                                                                            icon: "checkmark.circle.fill", tone: .success), for: 2.5)
                                                     }]),
                                    peek: true)
    }

    /// Debug: a call without making one (started `minutes` ago), or its end.
    func debugSimulate(_ on: Bool, minutes: Double = 5) {
        if on {
            withAnimation { call = Call(app: "Zoom", bundleID: "us.zoom.xos", started: Date().addingTimeInterval(-minutes * 60), event: "Design review", kept: true) }
        } else {
            quietSince = Date()
            end(prompt: true)
        }
    }

    /// Debug: the simulated call's app has let go of the microphone (the countdown to saving).
    func debugQuiet() {
        call?.kept = false
        evaluate()
    }

    /// The event on now (or about to start) that has a call link, else any timed one on now.
    private static func currentEvent(now: Date = Date()) -> EKEvent? {
        let events = CalendarManager.shared.events.filter { !$0.isAllDay && $0.startDate <= now.addingTimeInterval(600) && $0.endDate > now }
        return events.first { MeetingLinks.find(in: $0) != nil } ?? events.first
    }

    /// Who's invited, by name (an address alone says little to a transcriber).
    private static func attendees(_ event: EKEvent?) -> [String] {
        (event?.attendees ?? []).compactMap(\.name).filter { !$0.contains("@") }
    }
}

/// Which processes have audio input running, as Core Audio announces it. Core Audio doesn't post
/// changes to a process's "running input" (macOS reads it fine but never notifies), so it's
/// pieced together from what does: the list of audio processes, each process starting or
/// stopping any audio at all, and the default microphone starting or stopping for anyone.
/// `onChange` runs on the main queue after any of them; the caller reads who's on the mic then.
@MainActor
final class MicWatcher {
    private let onChange: () -> Void
    private var watched: Set<AudioObjectID> = []
    private var microphone = AudioObjectID(kAudioObjectUnknown)
    private var listAddress = AudioOutputManager.address(kAudioHardwarePropertyProcessObjectList)
    private var defaultInputAddress = AudioOutputManager.address(kAudioHardwarePropertyDefaultInputDevice)
    private var runningAddress = AudioOutputManager.address(kAudioProcessPropertyIsRunning)
    private var inputAddress = AudioOutputManager.address(kAudioProcessPropertyIsRunningInput)
    private var deviceRunningAddress = AudioOutputManager.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    private lazy var listChanged: AudioObjectPropertyListenerBlock = { _, _ in
        MainActor.assumeIsolated { [weak self] in self?.refresh() }
    }
    private lazy var changed: AudioObjectPropertyListenerBlock = { _, _ in
        MainActor.assumeIsolated { [weak self] in self?.onChange() }
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListenerBlock(system, &listAddress, .main, listChanged)
        AudioObjectAddPropertyListenerBlock(system, &defaultInputAddress, .main, listChanged)
        refresh()
    }

    /// Follows processes as they come and go, and the microphone if another becomes the default.
    private func refresh() {
        let now = Set(Self.processes())
        for gone in watched.subtracting(now) {
            AudioObjectRemovePropertyListenerBlock(gone, &runningAddress, .main, changed)
            AudioObjectRemovePropertyListenerBlock(gone, &inputAddress, .main, changed)
        }
        for new in now.subtracting(watched) {
            AudioObjectAddPropertyListenerBlock(new, &runningAddress, .main, changed)
            // Never posted today; harmless, and it'd be the precise one if it ever is.
            AudioObjectAddPropertyListenerBlock(new, &inputAddress, .main, changed)
        }
        watched = now
        let mic: AudioObjectID = AudioOutputManager.property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) ?? 0
        if mic != microphone {
            if microphone != kAudioObjectUnknown { AudioObjectRemovePropertyListenerBlock(microphone, &deviceRunningAddress, .main, changed) }
            if mic != kAudioObjectUnknown { AudioObjectAddPropertyListenerBlock(mic, &deviceRunningAddress, .main, changed) }
            microphone = mic
        }
        onChange()
    }

    private static func processes() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioOutputManager.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    func stop() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListenerBlock(system, &listAddress, .main, listChanged)
        AudioObjectRemovePropertyListenerBlock(system, &defaultInputAddress, .main, listChanged)
        for object in watched {
            AudioObjectRemovePropertyListenerBlock(object, &runningAddress, .main, changed)
            AudioObjectRemovePropertyListenerBlock(object, &inputAddress, .main, changed)
        }
        if microphone != kAudioObjectUnknown { AudioObjectRemovePropertyListenerBlock(microphone, &deviceRunningAddress, .main, changed) }
        watched = []
        microphone = AudioObjectID(kAudioObjectUnknown)
    }
}
