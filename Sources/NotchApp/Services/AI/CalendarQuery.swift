import Foundation

/// Answers questions about the user's schedule: "what's on tomorrow", "am I free friday at 3",
/// "when is my dentist appointment", "next meeting". The model only turns the question into a
/// query; the answer itself is computed from the real events, so it can't invent meetings.
@MainActor
enum CalendarQuery {
    enum Kind: String { case list, next, free, find }

    struct Query {
        var kind: Kind = .list
        var start: Date
        var end: Date
        /// The question named a specific time ("free friday at 3"), not just a day.
        var exactTime = false
        var search: String?
        var minutes = 30
    }

    static func answer(_ question: String, useAI: Bool) async throws -> CalendarAnswer {
        var query = parseWithoutAI(question)
        if useAI, let smart = try? await parse(question) { query = smart }
        query = narrowed(query, to: question)
        DebugHooks.log("CalendarQuery: \(question) → \(query.kind.rawValue) \(query.start)–\(query.end) search=\(query.search ?? "-") exact=\(query.exactTime)")
        do {
            if !UserDefaults.standard.bool(forKey: "debugDryRun") { try CalendarManager.shared.ensureAccess() }
        } catch {
            // Without the calendar, "what do I have to do today" can still answer from tasks.
            let tasks = query.kind == .list ? tasks(from: query.start, to: query.end) : []
            guard !tasks.isEmpty else { throw error }
            return CalendarAnswer(headline: taskHeadline(tasks.count, rangeLabel(query.start, query.end)),
                                  detail: "Calendar isn't connected", tasks: tasks)
        }
        return answer(for: query)
    }

    /// Open tasks for a range: due in it, plus (when it includes today) overdue ones and undated ones.
    static func tasks(from start: Date, to end: Date) -> [CalendarAnswer.TaskBrief] {
        let now = Date()
        let includesToday = start <= now && now < end
        return TaskStore.shared.open.filter { task in
            guard let due = task.due else { return includesToday }
            return (due >= start && due < end) || (includesToday && due < now)
        }
        .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        .map { CalendarAnswer.TaskBrief(id: $0.id, title: $0.title, due: $0.due, overdue: $0.isOverdue) }
    }

    private static func taskHeadline(_ count: Int, _ label: String) -> String {
        "\(count) task\(count == 1 ? "" : "s") \(label.lowercased() == "today" || label.lowercased() == "tomorrow" ? label.lowercased() : "· " + label)"
    }

    // MARK: - Understanding the question

    private static func parse(_ question: String) async throws -> Query {
        let system = """
        You turn a question about the user's own calendar into a query.
        \(DateContext.prompt)
        kind: "list" (what's on / my schedule / my day), "next" (next meeting or event), \
        "free" (am I free / when am I free / find time), "find" (when is a specific event).
        Reply with JSON only:
        {"kind": "list|next|free|find",
         "start": "YYYY-MM-DD for a day, or YYYY-MM-DDTHH:MM for an exact time",
         "end": "YYYY-MM-DD (inclusive last day) or YYYY-MM-DDTHH:MM, or null",
         "search": "words naming the event, or null",
         "minutes": length needed for "free" questions (default 30)}
        Defaults: no date → today ("find" with no date → the next 60 days). "This week" → today to Sunday.
        """
        let obj = try await OllamaClient.chatJSON(system: system, user: question)
        let cal = Calendar.current
        var q = Query(start: cal.startOfDay(for: Date()), end: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!)
        q.kind = Kind(rawValue: (obj["kind"] as? String ?? "").lowercased()) ?? .list
        q.search = (obj["search"] as? String).flatMap { $0.isEmpty || $0.lowercased() == "null" ? nil : $0 }
        q.minutes = max(15, (obj["minutes"] as? NSNumber)?.intValue ?? 30)
        if let start = DateContext.parse(obj["start"]) {
            q.exactTime = !start.dateOnly
            q.start = start.dateOnly ? cal.startOfDay(for: start.date) : start.date
            if let end = DateContext.parse(obj["end"]) {
                q.end = end.dateOnly ? cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end.date))! : end.date
            } else {
                q.end = start.dateOnly ? cal.date(byAdding: .day, value: 1, to: q.start)! : q.start.addingTimeInterval(Double(q.minutes * 60))
            }
        } else if q.kind == .find || q.kind == .next {
            q.start = Date()
            q.end = cal.date(byAdding: .day, value: 60, to: Date())!
        }
        if q.end <= q.start { q.end = q.start.addingTimeInterval(Double(max(q.minutes, 60) * 60)) }
        return q
    }

    /// "Tomorrow afternoon": a whole day narrowed to that part of it, whichever way the day was found.
    static func narrowed(_ q: Query, to question: String) -> Query {
        let cal = Calendar.current
        guard !q.exactTime, q.start == cal.startOfDay(for: q.start),
              q.end == cal.date(byAdding: .day, value: 1, to: q.start) else { return q }
        let lower = question.lowercased()
        let hours: (Int, Int)? = lower.contains("morning") ? (5, 12) : lower.contains("afternoon") ? (12, 17)
            : lower.contains("evening") || lower.contains("tonight") ? (17, 24) : nil
        guard let (from, to) = hours else { return q }
        var out = q
        out.start = cal.date(byAdding: .hour, value: from, to: q.start)!
        out.end = cal.date(byAdding: .hour, value: to, to: q.start)!
        return out
    }

    /// Keyword version for when no model is available.
    static func parseWithoutAI(_ question: String) -> Query {
        let lower = question.lowercased()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var q = Query(start: today, end: cal.date(byAdding: .day, value: 1, to: today)!)
        if lower.contains("free") || lower.contains("available") || lower.contains("busy") { q.kind = .free }
        else if lower.contains("next") { q.kind = .next }
        else if lower.hasPrefix("when") { q.kind = .find }

        if lower.contains("week") {
            let weekday = cal.component(.weekday, from: today) // 1 = Sunday
            q.end = cal.date(byAdding: .day, value: weekday == 1 ? 1 : 9 - weekday, to: today)!
        } else if let found = DueDateParser.detect(question) {
            q.exactTime = found.hasTime
            q.start = found.hasTime ? found.date : cal.startOfDay(for: found.date)
            q.end = found.hasTime ? found.date.addingTimeInterval(3600) : cal.date(byAdding: .day, value: 1, to: q.start)!
        } else if q.kind == .next || q.kind == .find {
            q.start = Date()
            q.end = cal.date(byAdding: .day, value: 60, to: Date())!
        }
        if q.kind == .find {
            let filler: Set<String> = ["when", "is", "my", "the", "what", "time", "next", "a", "an", "appointment", "meeting", "event", "on", "calendar"]
            let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !filler.contains($0) }
            q.search = words.isEmpty ? nil : words.joined(separator: " ")
        }
        return q
    }

    // MARK: - Answering from real events

    private static func answer(for q: Query) -> CalendarAnswer {
        let calendar = CalendarManager.shared
        let cal = Calendar.current
        let t = Date.FormatStyle(date: .omitted, time: .shortened)

        switch q.kind {
        case .next:
            let upcoming = calendar.summaries(from: Date(), to: q.end, matching: q.search).filter { !$0.allDay && $0.start > Date() }
            guard let next = upcoming.first else {
                return CalendarAnswer(headline: q.search.map { "Nothing coming up matching “\($0)”" } ?? "Nothing else on your calendar soon")
            }
            let until = BriefingService.duration(next.start.timeIntervalSinceNow)
            return CalendarAnswer(headline: "Next: \(next.title)",
                                  detail: "\(CommandParser.eventText(next.start, next.end, allDay: false)) · in \(until)",
                                  events: Array(upcoming.prefix(5)))

        case .find:
            let matches = calendar.summaries(from: q.start, to: q.end, matching: q.search)
            guard let first = matches.first else {
                return CalendarAnswer(headline: "No events matching “\(q.search ?? "that")”",
                                      detail: "Looked \(rangeLabel(q.start, q.end).lowercased())")
            }
            return CalendarAnswer(headline: first.title,
                                  detail: CommandParser.eventText(first.start, first.end, allDay: first.allDay)
                                      + (first.location.map { " · \($0)" } ?? ""),
                                  events: Array(matches.prefix(6)))

        case .free:
            if q.exactTime {
                let clashes = calendar.summaries(from: q.start, to: q.end).filter { !$0.allDay && $0.end > q.start && $0.start < q.end }
                let when = "\(dayLabel(q.start)) \(q.start.formatted(t)) – \(q.end.formatted(t))"
                return clashes.isEmpty
                    ? CalendarAnswer(headline: "You're free", detail: when)
                    : CalendarAnswer(headline: "You're busy then", detail: when, events: clashes)
            }
            // Working hours on the day(s) asked about, from now if that's today.
            // (Within the part of the day asked about, for "free tomorrow afternoon".)
            var slots: [DateInterval] = []
            var day = cal.startOfDay(for: q.start)
            let first = max(cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!, q.start)
            let last = min(cal.date(bySettingHour: 18, minute: 0, second: 0, of: day)!, q.end)
            while day < q.end, slots.count < 8 {
                let open = max(cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!, q.start, Date())
                let close = min(cal.date(bySettingHour: 18, minute: 0, second: 0, of: day)!, q.end)
                if open < close { slots += calendar.freeSlots(from: open, to: close, minutes: q.minutes) }
                day = cal.date(byAdding: .day, value: 1, to: day)!
            }
            let label = rangeLabel(q.start, q.end)
            let hours = "\(first.formatted(t)) – \(last.formatted(t))"
            return slots.isEmpty
                ? CalendarAnswer(headline: "No free \(q.minutes)-minute gaps", detail: "\(label), \(hours)")
                : CalendarAnswer(headline: "Free \(label.lowercased() == "today" ? "today" : "on " + label)",
                                 detail: "Gaps of \(q.minutes) min or more, \(hours)", free: slots)

        case .list:
            let events = calendar.summaries(from: q.start, to: q.end, matching: q.search)
            // Tasks belong in "what do I have to do", not in a search for one event.
            let tasks = q.search == nil ? tasks(from: q.start, to: q.end) : []
            let label = rangeLabel(q.start, q.end)
            let when = label.lowercased() == "today" || label.lowercased() == "tomorrow" ? label.lowercased() : "· " + label
            let parts = [events.isEmpty ? nil : "\(events.count) event\(events.count == 1 ? "" : "s")",
                         tasks.isEmpty ? nil : "\(tasks.count) task\(tasks.count == 1 ? "" : "s")"].compactMap { $0 }
            let headline = parts.isEmpty ? "Nothing on \(label.lowercased() == "today" ? "today" : label)"
                : "\(parts.joined(separator: " and ")) \(when)"
            let overdue = tasks.filter(\.overdue).count
            return CalendarAnswer(headline: headline, detail: overdue > 0 ? "\(overdue) overdue" : nil, events: events, tasks: tasks)
        }
    }

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private static func rangeLabel(_ start: Date, _ end: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: end).day ?? 1
        if days <= 1 { return dayLabel(start) }
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.addingTimeInterval(-1).formatted(.dateTime.month(.abbreviated).day()))"
    }
}
