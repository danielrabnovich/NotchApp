import AppKit
import EventKit
import SwiftUI

/// Meeting mode: notices a call (a call app or a browser using the microphone for a while), keeps a
/// timer and a mute button beside the notch while it lasts, and when it ends offers to jot notes
/// (in Ramble) or a follow-up task. Dictation apps using the microphone aren't calls.
@MainActor
final class MeetingMonitor: ObservableObject {
    static let shared = MeetingMonitor()

    struct Call: Equatable {
        let app: String
        let bundleID: String?
        let started: Date
        /// The calendar event it's probably for (on now, or starting within ten minutes).
        let event: String?
        var title: String { event ?? "Call on \(app)" }
    }

    @Published private(set) var call: Call?

    private var candidateSince: Date?
    private var quietSince: Date?
    private var cancellables: [Any] = []

    private static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime", "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "org.whispersystems.signal-desktop",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram", "com.skype.skype", "co.teamport.around",
        "com.loom.desktop", "com.riverside.desktop", "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    func start() {
        let privacy = PrivacyMonitor.shared
        cancellables.append(privacy.$micApps.sink { _ in DispatchQueue.main.async { MeetingMonitor.shared.evaluate() } })
        cancellables.append(AppSettings.shared.$meetingMode.sink { on in
            DispatchQueue.main.async {
                PrivacyMonitor.shared.meetingDemand = on
                if !on { MeetingMonitor.shared.end(prompt: false) }
            }
        })
        // A call starts counting after a little while, and ends after a quiet spell: checked on a clock
        // too, since the mic list may not change in between.
        cancellables.append(Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { _ in MeetingMonitor.shared.evaluate() })
    }

    private func evaluate() {
        guard AppSettings.shared.meetingMode else { return }
        let caller = PrivacyMonitor.shared.micApps.first { Self.callApps.contains($0.bundleID ?? "") }
        let now = Date()
        if let caller {
            quietSince = nil
            guard call == nil else { return }
            // Twenty seconds on the mic: a call, not a voice message.
            if candidateSince == nil { candidateSince = now }
            guard now.timeIntervalSince(candidateSince!) >= 20 else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                call = Call(app: caller.name, bundleID: caller.bundleID, started: candidateSince!, event: Self.currentEvent()?.title)
            }
        } else {
            candidateSince = nil
            guard call != nil else { return }
            if quietSince == nil { quietSince = now }
            // Half a minute off the mic (a reconnect, switching devices) before it counts as over.
            if now.timeIntervalSince(quietSince!) >= 30 { end(prompt: true) }
        }
    }

    private func end(prompt: Bool) {
        guard let call else { return }
        let minutes = Int((quietSince ?? Date()).timeIntervalSince(call.started) / 60)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self.call = nil }
        quietSince = nil
        candidateSince = nil
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
            withAnimation { call = Call(app: "Zoom", bundleID: "us.zoom.xos", started: Date().addingTimeInterval(-minutes * 60), event: "Design review") }
        } else {
            quietSince = Date()
            end(prompt: true)
        }
    }

    /// The event on now (or about to start) that has a call link, else any timed one on now.
    private static func currentEvent(now: Date = Date()) -> EKEvent? {
        let events = CalendarManager.shared.events.filter { !$0.isAllDay && $0.startDate <= now.addingTimeInterval(600) && $0.endDate > now }
        return events.first { MeetingLinks.find(in: $0) != nil } ?? events.first
    }
}
