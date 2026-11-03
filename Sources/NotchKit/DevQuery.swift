import Foundation

/// What a search-bar query asks of Linear or Vercel, when it plainly does.
public enum DevQuery: Equatable, Sendable {
    /// One Linear issue by its key ("ENG-123", or its link).
    case linearIssue(String)
    /// Your open Linear issues.
    case linearMine
    case linearSearch(String)
    /// Recent Vercel deployments, of one project when named.
    case deploys(project: String?)

    public static func parse(_ raw: String) -> DevQuery? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = q.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?!."))
        guard !lower.isEmpty else { return nil }

        if let m = groups(#"linear\.app/[\w-]+/issue/([A-Za-z][A-Za-z0-9]{0,6}-\d+)"#, q) { return .linearIssue(m[1].uppercased()) }
        if let m = groups(#"^([A-Za-z][A-Za-z0-9]{0,6}-\d+)$"#, q) { return .linearIssue(m[1].uppercased()) }

        let mine: Set<String> = ["my issues", "linear", "my linear issues", "linear issues", "my linear", "what am i working on",
                                 "what should i work on", "my tickets", "tickets", "in progress", "my todo issues"]
        if mine.contains(lower) { return .linearMine }
        if let m = groups(#"^linear\s+(.+)$"#, lower) { return .linearSearch(m[1].trimmingCharacters(in: .whitespaces)) }

        let deploys: Set<String> = ["deploys", "deployments", "vercel", "my deploys", "vercel deploys", "vercel deployments", "previews",
                                    "preview deployments", "deploy status", "latest deploy", "latest deploys"]
        if deploys.contains(lower) { return .deploys(project: nil) }
        if let m = groups(#"^(?:deploys?|deployments?|vercel|previews?)\s+(?:of\s+|for\s+)?([\w.-]+)$"#, lower) { return .deploys(project: m[1]) }
        return nil
    }

    private static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}
