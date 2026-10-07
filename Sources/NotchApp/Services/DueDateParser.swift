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
}
