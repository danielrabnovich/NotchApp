import Foundation

/// Pulls a due date out of free text: "Send deck by Friday 3pm" → ("Send deck", Fri 15:00).
enum DueDateParser {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    static func extract(from text: String) -> (title: String, due: Date?) {
        guard let detector,
              let match = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              var date = match.date,
              let range = Range(match.range, in: text) else { return (text, nil) }

        let phrase = text[range].lowercased()
        // "by Friday" has no time: treat it as end of the working day instead of noon.
        let mentionsTime = phrase.contains(where: \.isNumber) && (phrase.contains(":") || phrase.contains("am") || phrase.contains("pm"))
            || ["noon", "morning", "afternoon", "evening", "tonight", "midnight"].contains { phrase.contains($0) }
        if !mentionsTime {
            date = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: date) ?? date
        }
        // Ignore dates in the past (e.g. "the Oct 2 report").
        guard date > Date().addingTimeInterval(-60) else { return (text, nil) }

        var title = text
        title.removeSubrange(range)
        // Drop the connecting word left dangling before the date ("send deck by" → "send deck").
        let dangling = ["by", "on", "due", "before", "at", "until", "for", "this", "next", "-", "–", ","]
        var words = title.split(separator: " ").map(String.init)
        while let last = words.last, dangling.contains(last.lowercased()) { words.removeLast() }
        title = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if title.isEmpty { title = text }
        return (title.prefix(1).uppercased() + title.dropFirst(), date)
    }

    private static func mentionsTime(_ phrase: String) -> Bool {
        let p = phrase.lowercased()
        return p.contains(where: \.isNumber) && (p.contains(":") || p.contains("am") || p.contains("pm"))
            || ["noon", "morning", "afternoon", "evening", "tonight", "midnight"].contains { p.contains($0) }
    }

    /// The first date in some text, and whether it included a time of day.
    static func detect(_ text: String) -> (date: Date, hasTime: Bool, range: Range<String.Index>)? {
        guard let detector,
              let match = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).first,
              let date = match.date, let range = Range(match.range, in: text) else { return nil }
        return (date, mentionsTime(String(text[range])), range)
    }

    /// "lunch with sam friday 1pm for 90 min" → title, start, length. Without a time it's all-day.
    static func event(from text: String) -> EventDraft? {
        var rest = text
        // A length: "for 30 min", "for 2h", "1 hour".
        var minutes = 60
        if let r = rest.range(of: #"\b(for\s+)?(\d+(\.\d+)?)\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes)\b"#,
                              options: [.regularExpression, .caseInsensitive]) {
            let phrase = String(rest[r]).lowercased().replacingOccurrences(of: "for", with: "")
            if let m = CommandParser.minutes(in: phrase), m > 0, m <= 24 * 60 { minutes = m; rest.removeSubrange(r) }
        }
        guard let found = detect(rest) else { return nil }
        var title = rest
        title.removeSubrange(found.range)
        let dangling: Set<String> = ["on", "at", "for", "this", "next", "from", "-", "–", ","]
        var words = title.split(separator: " ").map(String.init)
        while let last = words.last, dangling.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, dangling.contains(first.lowercased()) { words.removeFirst() }
        title = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !title.isEmpty else { return nil }
        title = title.prefix(1).uppercased() + title.dropFirst()
        if found.hasTime {
            return EventDraft(title: title, start: found.date, end: found.date.addingTimeInterval(Double(minutes * 60)))
        }
        let day = Calendar.current.startOfDay(for: found.date)
        return EventDraft(title: title, start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day)!, allDay: true)
    }
}
