import AppKit
import EventKit

/// A new event, as described by the user (or the model).
struct EventDraft: Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    var location: String?
    var notes: String?
    /// Which calendar to use, by name ("Work"); nil means the default.
    var calendarName: String?
}

/// An event, copied out of EventKit so results can be stored and compared.
struct EventSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?
    let calendar: String

    var timeText: String {
        if allDay { return "All day" }
        let t = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(start.formatted(t)) – \(end.formatted(t))"
    }
}

/// What the search bar shows for a calendar question.
struct CalendarAnswer: Equatable, Sendable {
    struct TaskBrief: Equatable, Sendable, Identifiable {
        var id: UUID
        var title: String
        var due: Date?
        var overdue: Bool
    }

    var headline: String
    var detail: String?
    var events: [EventSummary] = []
    var free: [DateInterval] = []
    /// "What do I have to do today" is about tasks as much as meetings.
    var tasks: [TaskBrief] = []
}

/// Calendar operations for the search bar. They go through EventKit, so they cover every calendar
/// the Mac knows about: iCloud, plus Google, Exchange/Outlook and others added in
/// System Settings → Internet Accounts (changes sync back to those services).
extension CalendarManager {
    enum ToolError: LocalizedError {
        case noAccess, notFound(String), readOnly(String)

        var errorDescription: String? {
            switch self {
            case .noAccess: "NotchApp needs calendar access. Allow it in the prompt, or in System Settings → Privacy & Security → Calendars."
            case .notFound(let what): "Couldn't find an event matching “\(what)”."
            case .readOnly(let name): "The “\(name)” calendar is read-only."
            }
        }
    }

    func ensureAccess() throws {
        let now = EKEventStore.authorizationStatus(for: .event)
        guard now == .fullAccess else {
            requestAccess()
            throw ToolError.noAccess
        }
    }

    var writableCalendars: [EKCalendar] {
        store.calendars(for: .event).filter(\.allowsContentModifications)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// A calendar by (partial) name; otherwise the user's chosen default, then the system default.
    func targetCalendar(named name: String?) -> EKCalendar? {
        let writable = writableCalendars
        if let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty,
           let match = writable.first(where: { $0.title.lowercased() == name })
            ?? writable.first(where: { $0.title.lowercased().contains(name) }) {
            return match
        }
        let preferred = AppSettings.shared.defaultCalendarID
        if !preferred.isEmpty, let cal = store.calendar(withIdentifier: preferred), cal.allowsContentModifications { return cal }
        return store.defaultCalendarForNewEvents ?? writable.first
    }

    // MARK: - Write

    /// Creates the event and returns its identifier (for undo).
    @discardableResult
    func create(_ draft: EventDraft) throws -> String {
        try ensureAccess()
        guard let calendar = targetCalendar(named: draft.calendarName) else { throw ToolError.readOnly(draft.calendarName ?? "default") }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = max(draft.end, draft.start.addingTimeInterval(draft.allDay ? 0 : 15 * 60))
        event.isAllDay = draft.allDay
        event.location = draft.location
        event.notes = draft.notes
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        reload()
        return event.eventIdentifier ?? ""
    }

    /// Moves an event, keeping its length unless a new end is given. Returns the old times (for undo).
    @discardableResult
    func move(id: String, to start: Date, end: Date?) throws -> (start: Date, end: Date) {
        try ensureAccess()
        guard let event = store.event(withIdentifier: id) else { throw ToolError.notFound("that event") }
        guard event.calendar?.allowsContentModifications != false else { throw ToolError.readOnly(event.calendar?.title ?? "") }
        let old = (event.startDate!, event.endDate!)
        let length = old.1.timeIntervalSince(old.0)
        event.startDate = start
        event.endDate = end ?? start.addingTimeInterval(length)
        try store.save(event, span: .thisEvent, commit: true)
        reload()
        return old
    }

    /// Deletes an event and returns a draft that can recreate it (for undo).
    @discardableResult
    func delete(id: String) throws -> EventDraft {
        try ensureAccess()
        guard let event = store.event(withIdentifier: id) else { throw ToolError.notFound("that event") }
        guard event.calendar?.allowsContentModifications != false else { throw ToolError.readOnly(event.calendar?.title ?? "") }
        let draft = EventDraft(title: event.title ?? "Event", start: event.startDate, end: event.endDate,
                               allDay: event.isAllDay, location: event.location, notes: event.notes,
                               calendarName: event.calendar?.title)
        try store.remove(event, span: .thisEvent, commit: true)
        reload()
        return draft
    }

    // MARK: - Read

    func summaries(from start: Date, to end: Date, matching query: String? = nil) -> [EventSummary] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var found = store.events(matching: predicate)
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            found = found.filter { Self.score(query, $0) > 0 }
        }
        return found.sorted { ($0.startDate, $0.isAllDay ? 0 : 1) < ($1.startDate, $1.isAllDay ? 0 : 1) }.map(Self.summary)
    }

    /// The event that best matches a description, preferring ones near the given date.
    func findEvent(_ query: String, near date: Date?) -> EKEvent? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let cal = Calendar.current
        let center = date ?? Date()
        let from = cal.date(byAdding: .day, value: date == nil ? -1 : -2, to: cal.startOfDay(for: center))!
        let to = cal.date(byAdding: .day, value: date == nil ? 60 : 3, to: cal.startOfDay(for: center))!
        let candidates = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
        // "my 3pm meeting": an event starting at that time counts as a strong match.
        let mentioned = DueDateParser.detect(query).flatMap { $0.hasTime ? $0.date : nil }
        let cal2 = Calendar.current
        func timeMatches(_ e: EKEvent) -> Bool {
            guard let mentioned, !e.isAllDay else { return false }
            return cal2.component(.hour, from: e.startDate) == cal2.component(.hour, from: mentioned)
                && cal2.component(.minute, from: e.startDate) == cal2.component(.minute, from: mentioned)
        }
        var best: EKEvent?
        var bestScore = 0
        var bestDistance = Double.infinity
        for event in candidates {
            let score = Self.score(query, event) + (timeMatches(event) ? 5 : 0)
            guard score > 0 else { continue }
            let distance = abs(event.startDate.timeIntervalSince(center))
            if score > bestScore || (score == bestScore && distance < bestDistance) {
                best = event; bestScore = score; bestDistance = distance
            }
        }
        return best
    }

    /// Free stretches of at least `minutes` between `start` and `end`, around timed events.
    func freeSlots(from start: Date, to end: Date, minutes: Int) -> [DateInterval] {
        let busy = summaries(from: start, to: end).filter { !$0.allDay }
            .map { DateInterval(start: max($0.start, start), end: min($0.end, end)) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        var slots: [DateInterval] = []
        var cursor = start
        for b in busy {
            if b.start.timeIntervalSince(cursor) >= Double(minutes * 60) { slots.append(DateInterval(start: cursor, end: b.start)) }
            cursor = max(cursor, b.end)
        }
        if end.timeIntervalSince(cursor) >= Double(minutes * 60) { slots.append(DateInterval(start: cursor, end: end)) }
        return slots
    }

    static func summary(_ e: EKEvent) -> EventSummary {
        EventSummary(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Untitled", start: e.startDate,
                     end: e.endDate, allDay: e.isAllDay, location: e.location?.isEmpty == false ? e.location : nil,
                     calendar: e.calendar?.title ?? "")
    }

    /// How well an event's title matches a description (shared words, ignoring filler).
    private static func score(_ query: String, _ event: EKEvent) -> Int {
        let filler: Set<String> = ["the", "my", "a", "an", "with", "meeting", "event", "appointment", "call", "on", "at", "to", "for"]
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let wanted = words.filter { $0.count > 1 && !filler.contains($0) }
        let title = (event.title ?? "").lowercased()
        let hits = wanted.filter { title.contains($0) }.count
        if hits > 0 { return hits * 2 }
        // "the meeting" with nothing more specific: any event counts a little.
        return wanted.isEmpty ? 1 : 0
    }
}

// MARK: - Dates for the model

/// Gives the model unambiguous dates, and reads the ones it sends back.
enum DateContext {
    /// "Now is Wednesday, October 7, 2026 at 6:40 PM … Thu = 2026-10-08 …" for the next two weeks.
    static var prompt: String {
        let now = Date()
        let cal = Calendar.current
        let iso = isoDay
        var days: [String] = []
        for offset in 0..<15 {
            let d = cal.date(byAdding: .day, value: offset, to: now)!
            let label = offset == 0 ? "today" : offset == 1 ? "tomorrow" : (offset < 7 ? "this " : "next ") + d.formatted(.dateTime.weekday(.wide))
            days.append("\(label) \(d.formatted(.dateTime.weekday(.abbreviated))) = \(iso.string(from: d))")
        }
        return """
        It is now \(now.formatted(date: .complete, time: .shortened)) (\(TimeZone.current.identifier)).
        Dates: \(days.joined(separator: "; ")).
        Write times as local "YYYY-MM-DDTHH:MM" (24-hour) and whole days as "YYYY-MM-DD".
        """
    }

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Parses what the model wrote; `dateOnly` is true for "YYYY-MM-DD".
    static func parse(_ raw: Any?) -> (date: Date, dateOnly: Bool)? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.lowercased() != "null" else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return (d, false) }
        }
        if let d = isoDay.date(from: String(s.prefix(10))), s.count <= 10 { return (d, true) }
        // Last resort: natural language ("friday 3pm").
        if let d = DueDateParser.detect(s) { return (d.date, !d.hasTime) }
        return nil
    }
}
