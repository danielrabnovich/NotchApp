import AppKit
import Combine
import EventKit

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published private(set) var events: [EKEvent] = []
    /// The first timed event after today (within a week), for Home when today has nothing left.
    @Published private(set) var later: EKEvent?
    /// Everything in this calendar week and four days either side of today, past days too, for Home's week strip.
    @Published private(set) var week: [EKEvent] = []
    @Published private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    let store = EKEventStore()
    private var timer: Timer?
    private var alerted = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    var hasAccess: Bool { status == .fullAccess }

    func start() {
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        AppSettings.shared.$calendarEnabled
            .sink { [weak self] enabled in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if enabled { self.activate() } else { self.deactivate() }
                }
            }
            .store(in: &cancellables)
    }

    private func activate() {
        if status == .notDetermined { requestAccess() } else { reload() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func deactivate() {
        timer?.invalidate()
        timer = nil
        events = []
        week = []
    }

    func requestAccess() {
        if status == .denied || status == .restricted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            return
        }
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = EKEventStore.authorizationStatus(for: .event)
                self.reload()
            }
        }
    }

    func reload() {
        guard !previewing else { return }
        status = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess, AppSettings.shared.calendarEnabled else { events = []; later = nil; week = []; return }
        let now = Date()
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.isAllDay || $0.endDate > now }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
        let week = store.predicateForEvents(withStart: end, end: cal.date(byAdding: .day, value: 7, to: end)!, calendars: nil)
        later = store.events(matching: week).filter { !$0.isAllDay }.min { $0.startDate < $1.startDate }
        // The week strip's days: this calendar week, or four days either side of today when it's wide.
        if let days = cal.dateInterval(of: .weekOfYear, for: now) {
            let from = min(days.start, cal.date(byAdding: .day, value: -4, to: start)!)
            let to = max(days.end, cal.date(byAdding: .day, value: 5, to: start)!)
            self.week = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
                .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
        }
        checkAlerts(now: now)
    }

    private func checkAlerts(now: Date) {
        let settings = AppSettings.shared
        guard settings.meetingAlerts else { return }
        let window = TimeInterval(settings.meetingAlertMinutes * 60)
        for event in events where !event.isAllDay {
            let until = event.startDate.timeIntervalSince(now)
            let key = (event.eventIdentifier ?? event.title) + "\(event.startDate.timeIntervalSince1970)"
            guard until > 0, until <= window, !alerted.contains(key) else { continue }
            alerted.insert(key)
            let minutes = max(1, Int((until / 60).rounded(.up)))
            ActivityCenter.shared.show(.meeting(title: event.title ?? "Event", minutes: minutes,
                                                color: event.calendar?.color ?? .systemBlue), for: 8)
            // With a call link, opening the notch now offers to join.
            if let link = MeetingLinks.find(in: event) {
                NotchPresenter.shared.offer(Prompt(icon: "video.fill", tint: event.calendar?.color ?? .systemBlue,
                                                   title: event.title ?? "Meeting",
                                                   detail: "Starts in \(minutes) min · \(link.service)",
                                                   actions: [.init(title: "Join \(link.service)", primary: true) { MeetingLinks.join(link) }]),
                                            peek: false)
            }
            break
        }
    }

    /// Debug (`homeshot`): shows these as today's events, with no reloads until it ends (nil).
    func preview(events: [EKEvent]?) {
        previewing = events != nil
        if let events {
            self.events = events
            later = nil
        } else {
            reload()
        }
    }
    private var previewing = false

    func openCalendar() {
        NSWorkspace.shared.open(URL(string: "ical://")!)
    }
}
