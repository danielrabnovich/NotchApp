import AppKit
import Combine

/// A nudge to get up after a long unbroken stretch at the Mac, timed for a moment you're only
/// waiting anyway. The stretch is time with no pause of five minutes or more (stepping away, the
/// lock screen); past 50 minutes, the first coding agent starting to work or Xcode build
/// beginning brings the Banner, and past 70 it comes regardless. Never on a call, never during
/// a Pomodoro (it has breaks of its own), and once a stretch: a real pause starts the count over.
@MainActor
final class Breaks {
    static let shared = Breaks()

    private var stretchStart = Date()
    private var nudged = false
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Minutes of stretch before a good moment counts, and before any moment does.
    private static let ready: TimeInterval = 50 * 60, overdue: TimeInterval = 70 * 60
    /// A pause this long is a break already taken.
    private static let pause: TimeInterval = 5 * 60

    func start() {
        AppSettings.shared.$breakReminders.removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async { self?.set(on) }
        }.store(in: &cancellables)
        Presence.shared.$away.removeDuplicates().sink { [weak self] away in
            if away { self?.reset() }
        }.store(in: &cancellables)
        // The waiting moments: an agent starting to work, a build beginning.
        AgentMonitor.shared.$sessions
            .map { $0.first { $0.state == .working }.map { "\($0.tool.name) is working in \($0.project)" } }
            .removeDuplicates { ($0 == nil) == ($1 == nil) }
            .compactMap { $0 }
            .sink { [weak self] moment in self?.check(goodMoment: moment) }
            .store(in: &cancellables)
    }

    func buildStarted(_ project: String) { check(goodMoment: "\(project) is building") }

    private func set(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        reset()
        guard on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { Breaks.shared.check(goodMoment: nil) } }
        timer?.tolerance = 15
    }

    private func reset() {
        stretchStart = Date()
        nudged = false
    }

    private func check(goodMoment: String?) {
        guard AppSettings.shared.breakReminders, !Presence.shared.away else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= Self.pause { return reset() }
        let stretch = Date().timeIntervalSince(stretchStart)
        guard !nudged, stretch >= (goodMoment == nil ? Self.overdue : Self.ready),
              MeetingMonitor.shared.call == nil, TimerStore.shared.state != .running || TimerStore.shared.runningMode != .pomodoro else { return }
        nudged = true
        let minutes = Int(stretch / 60)
        let title = minutes >= 90 ? "\(minutes / 60) h \(minutes % 60) min without a break" : "\(minutes) minutes without a break"
        let detail = goodMoment.map { "\($0): a good minute to stand up" } ?? "Stand up, look at something far away"
        ActivityCenter.shared.show(.notice(title: title, detail: detail, icon: "figure.walk", tone: .info), for: 8)
    }
}
