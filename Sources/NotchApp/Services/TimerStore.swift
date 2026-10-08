import AppKit
import SwiftUI

/// Publishes once per displayed second, kept apart from TimerStore so only the views that
/// show the time redraw while a timer runs.
@MainActor
final class TimerClock: ObservableObject {
    @Published fileprivate(set) var tick = 0
}

/// Countdown timer, Pomodoro cycles and a stopwatch. Settings persist across launches.
@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()

    enum Mode: String, CaseIterable, Identifiable {
        case timer, pomodoro, stopwatch
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .timer: "timer"
            case .pomodoro: "brain.head.profile"
            case .stopwatch: "stopwatch"
            }
        }
    }

    enum Phase: Equatable {
        case focus, shortBreak, longBreak
        var label: String {
            switch self {
            case .focus: "Focus"
            case .shortBreak: "Short break"
            case .longBreak: "Long break"
            }
        }
        var icon: String { self == .focus ? "brain.head.profile" : "cup.and.saucer.fill" }
    }

    enum State { case idle, running, paused }

    let clock = TimerClock()

    @Published var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "timer.mode") } }
    @Published var timerMinutes: Int { didSet { defaults.set(timerMinutes, forKey: "timer.minutes") } }
    @Published var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: "timer.focus") } }
    @Published var shortBreakMinutes: Int { didSet { defaults.set(shortBreakMinutes, forKey: "timer.shortBreak") } }
    @Published var longBreakMinutes: Int { didSet { defaults.set(longBreakMinutes, forKey: "timer.longBreak") } }
    @Published var sessionsBeforeLongBreak: Int { didSet { defaults.set(sessionsBeforeLongBreak, forKey: "timer.sessionsBeforeLong") } }
    @Published var totalSessions: Int { didSet { defaults.set(totalSessions, forKey: "timer.totalSessions") } }

    @Published private(set) var state: State = .idle
    /// The mode of the run in progress (the picker can't change while running).
    @Published private(set) var runningMode: Mode = .timer
    @Published private(set) var phase: Phase = .focus
    /// 1-based focus session number.
    @Published private(set) var session = 1
    @Published private(set) var laps: [TimeInterval] = []

    private let defaults = UserDefaults.standard
    /// Countdown: when the current phase ends. Stopwatch: when it (re)started.
    private var anchor: Date?
    /// Time left (countdown) or elapsed (stopwatch) when paused.
    private var banked: TimeInterval = 0
    private var ticker: Timer?
    private var lastShownSecond = -1

    private init() {
        defaults.register(defaults: [
            "timer.mode": Mode.pomodoro.rawValue,
            "timer.minutes": 10,
            "timer.focus": 25,
            "timer.shortBreak": 5,
            "timer.longBreak": 15,
            "timer.sessionsBeforeLong": 4,
            "timer.totalSessions": 4,
        ])
        mode = Mode(rawValue: defaults.string(forKey: "timer.mode") ?? "") ?? .pomodoro
        timerMinutes = defaults.integer(forKey: "timer.minutes")
        focusMinutes = defaults.integer(forKey: "timer.focus")
        shortBreakMinutes = defaults.integer(forKey: "timer.shortBreak")
        longBreakMinutes = defaults.integer(forKey: "timer.longBreak")
        sessionsBeforeLongBreak = defaults.integer(forKey: "timer.sessionsBeforeLong")
        totalSessions = defaults.integer(forKey: "timer.totalSessions")
    }

    // MARK: - Reading

    var isActive: Bool { state != .idle }

    /// Full length of the current countdown phase.
    var duration: TimeInterval {
        switch isActive ? runningMode : mode {
        case .timer: TimeInterval(timerMinutes * 60)
        case .pomodoro: TimeInterval(minutes(for: phase) * 60)
        case .stopwatch: 0
        }
    }

    /// Seconds left for countdowns, seconds elapsed for the stopwatch.
    var displaySeconds: TimeInterval {
        let m = isActive ? runningMode : mode
        if m == .stopwatch {
            guard state == .running, let anchor else { return banked }
            return banked + Date().timeIntervalSince(anchor)
        }
        switch state {
        case .idle: return duration
        case .paused: return banked
        case .running: return max(0, anchor.map { $0.timeIntervalSinceNow } ?? 0)
        }
    }

    /// 0 → 1 through the current countdown.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return 1 - displaySeconds / duration
    }

    var displayTime: String { Self.format(displaySeconds, roundUp: (isActive ? runningMode : mode) != .stopwatch) }

    static func format(_ seconds: TimeInterval, roundUp: Bool = false) -> String {
        let total = Int(roundUp ? seconds.rounded(.up) : seconds.rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    func minutes(for phase: Phase) -> Int {
        switch phase {
        case .focus: focusMinutes
        case .shortBreak: shortBreakMinutes
        case .longBreak: longBreakMinutes
        }
    }

    /// What comes after the current Pomodoro phase.
    var nextPhase: Phase? {
        switch phase {
        case .focus:
            if session >= totalSessions { return nil }
            return session % max(1, sessionsBeforeLongBreak) == 0 ? .longBreak : .shortBreak
        case .shortBreak, .longBreak: return .focus
        }
    }

    // MARK: - Controls

    func start() {
        runningMode = mode
        phase = .focus
        session = 1
        laps = []
        banked = 0
        begin(countdown: mode == .stopwatch ? nil : duration)
    }

    func pause() {
        guard state == .running else { return }
        banked = displaySeconds
        anchor = nil
        state = .paused
        stopTicker()
    }

    func resume() {
        guard state == .paused else { return }
        begin(countdown: runningMode == .stopwatch ? nil : banked)
    }

    func reset() {
        stopTicker()
        state = .idle
        anchor = nil
        banked = 0
        phase = .focus
        session = 1
        laps = []
        clock.tick += 1
    }

    /// Ends the current Pomodoro phase early.
    func skip() {
        guard isActive, runningMode == .pomodoro else { return }
        advancePomodoro(chime: false)
    }

    func lap() {
        guard runningMode == .stopwatch, state == .running else { return }
        laps.insert(displaySeconds, at: 0)
    }

    // MARK: - Running

    private func begin(countdown: TimeInterval?) {
        if let countdown {
            anchor = Date().addingTimeInterval(countdown)
        } else {
            anchor = Date()
        }
        state = .running
        lastShownSecond = -1
        stopTicker()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { TimerStore.shared.tick() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        tick()
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        let seconds = displaySeconds
        let shown = Int(runningMode == .stopwatch ? seconds.rounded(.down) : seconds.rounded(.up))
        if shown != lastShownSecond {
            lastShownSecond = shown
            clock.tick += 1
        }
        guard runningMode != .stopwatch, seconds <= 0 else { return }
        if runningMode == .pomodoro {
            advancePomodoro(chime: true)
        } else {
            reset()
            finish(message: "Time's up", sound: "Glass")
        }
    }

    private func advancePomodoro(chime: Bool) {
        guard let next = nextPhase else {
            reset()
            finish(message: "Pomodoro complete · \(totalSessions) sessions", sound: chime ? "Hero" : nil)
            return
        }
        if next == .focus { session += 1 }
        phase = next
        let message = next == .focus
            ? "Focus · session \(session) of \(totalSessions)"
            : "\(next.label) · \(minutes(for: next)) min"
        if AppSettings.shared.pomodoroAutoStart {
            begin(countdown: duration)
        } else {
            stopTicker()
            banked = duration
            anchor = nil
            state = .paused
            clock.tick += 1
        }
        finish(message: message, sound: chime ? (next == .focus ? "Ping" : "Glass") : nil)
    }

    private func finish(message: String, sound: String?) {
        if let sound, AppSettings.shared.timerSounds { NSSound(named: sound)?.play() }
        ActivityCenter.shared.show(.timer(message: message), for: 4)
    }
}
