import Foundation

/// One emoji (or character) the picker offers: what it is, its name, the words it's found by, and
/// its five skin tones when it has them.
public struct Emoji: Decodable, Hashable, Sendable, Identifiable {
    public let character: String
    public let name: String
    public let keywords: [String]
    /// Light to dark, when the emoji comes in all five.
    public let tones: [String]?
    /// The name split up once, for matching on every keystroke.
    let nameMatch: FuzzyMatch.Name
    let nameLower: String
    let keywordsLower: [String]

    public var id: String { character }

    public init(character: String, name: String, keywords: [String] = [], tones: [String]? = nil) {
        self.character = character
        self.name = name
        self.keywords = keywords
        self.tones = tones
        nameMatch = FuzzyMatch.Name(name)
        nameLower = name.lowercased()
        keywordsLower = keywords.map { $0.lowercased() }
    }

    private enum CodingKeys: String, CodingKey { case e, n, k, t }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(character: try c.decode(String.self, forKey: .e), name: try c.decode(String.self, forKey: .n),
                  keywords: (try c.decodeIfPresent(String.self, forKey: .k) ?? "").split(separator: " ").map(String.init),
                  tones: try c.decodeIfPresent([String].self, forKey: .t))
    }

    /// In skin tone `tone` (1–5, light to dark); as it is for 0, or when it has no tones.
    public func toned(_ tone: Int) -> String {
        guard let tones, (1...5).contains(tone) else { return character }
        return tones[tone - 1]
    }

    public static func == (a: Emoji, b: Emoji) -> Bool { a.character == b.character }
    public func hash(into hasher: inout Hasher) { hasher.combine(character) }
}

public struct EmojiGroup: Decodable, Sendable, Identifiable {
    public let name: String
    public let emoji: [Emoji]
    public var id: String { name }

    public init(name: String, emoji: [Emoji]) {
        self.name = name
        self.emoji = emoji
    }
}

/// Every emoji, in the system keyboard's groups and order (Resources/Emoji.json, from
/// scripts/build-emoji.py), and finding them by what's typed.
public struct EmojiCatalog: Sendable {
    public let groups: [EmojiGroup]
    private let all: [Emoji]

    public init(groups: [EmojiGroup]) {
        self.groups = groups
        all = groups.flatMap(\.emoji)
    }

    public init(json: Data) throws {
        struct File: Decodable { let groups: [EmojiGroup] }
        self.init(groups: try JSONDecoder().decode(File.self, from: json).groups)
    }

    /// The same groups with only the emoji `keep` says yes to (those this Mac can draw), and none left empty.
    public func filtered(_ keep: (EmojiGroup, Emoji) -> Bool) -> EmojiCatalog {
        EmojiCatalog(groups: groups.map { g in EmojiGroup(name: g.name, emoji: g.emoji.filter { keep(g, $0) }) }.filter { !$0.emoji.isEmpty })
    }

    public func emoji(_ character: String) -> Emoji? { all.first { $0.character == character } }

    /// What's typed, best first: an emoticon's emoji (":)" → 🙂), then names and the words they're
    /// known by. `boost` (by character, a few points) lifts the ones used often among equals.
    public func search(_ query: String, boost: [String: Int] = [:], limit: Int = 300) -> [Emoji] {
        let raw = query.trimmingCharacters(in: .whitespaces)
        let q = raw.lowercased()
        guard !q.isEmpty else { return [] }
        var lead: [Emoji] = []
        // As typed, or after the picker's own ":" ("::)" leaves ")").
        if let e = Self.emoticons[raw] ?? Self.emoticons[q] ?? Self.emoticons[":" + raw], let found = emoji(e) { lead.append(found) }
        let words = q.split(separator: " ").map(String.init)
        let ranked = all.enumerated().compactMap { i, e -> (Emoji, Int, Int)? in
            let s = Self.score(e, q, words)
            return s > 0 ? (e, s + (boost[e.character] ?? 0), i) : nil
        }
        // Equal scores keep the keyboard's order, so related emoji stay together.
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        .map(\.0)
        return Array((lead + ranked.filter { !lead.contains($0) }).prefix(limit))
    }

    /// 0 when it doesn't fit. The name counts as `FuzzyMatch` scores it (only its closer tiers:
    /// letters merely in order would match half the list); a keyword typed whole comes just after
    /// the name's start ("thumb": 👍 thumbs up, then 🫰 with "thumb" among its words), and the
    /// start of one a little after that. Several words each have to start a word
    /// of the name or a keyword ("red heart", "heart red").
    static func score(_ e: Emoji, _ q: String, _ words: [String]) -> Int {
        // With symbols in it ("+1", "<3"), as typed: fuzzy matching would drop the "+" and find "1st place medal".
        var best = q.contains(where: { !$0.isLetter && !$0.isNumber && $0 != " " })
            ? (e.nameLower.contains(q) ? 85 : 0)
            : FuzzyMatch.score(e.nameMatch, q)
        if best < 60 { best = 0 }
        for k in e.keywordsLower {
            if k == q { best = max(best, 82) } else if q.count >= 2, k.hasPrefix(q) { best = max(best, 72) }
        }
        if words.count > 1, best < 66 {
            let tokens = e.nameMatch.parts + e.keywordsLower
            if words.allSatisfy({ w in tokens.contains { $0.hasPrefix(w) } }) { best = 66 }
        }
        return best
    }

    /// Typed faces and the emoji they mean.
    static let emoticons: [String: String] = [
        ":)": "🙂", ":-)": "🙂", ":]": "🙂", ":D": "😀", ":-D": "😀", "xD": "😆", "XD": "😆", ";)": "😉", ";-)": "😉",
        ":(": "🙁", ":-(": "🙁", ":'(": "😢", ":P": "😛", ":-P": "😛", ";P": "😜", ":O": "😮", ":-O": "😮",
        ":|": "😐", ":-|": "😐", ":/": "😕", ":-/": "😕", ":*": "😘", ":-*": "😘", "B)": "😎", "8)": "😎",
        "^_^": "😊", "^^": "😊", "-_-": "😑", "o_O": "🤨", "O_o": "🤨", ">:(": "😠", "<3": "❤️", "</3": "💔",
        "o/": "👋", "\\o/": "🙌", ":+1:": "👍", ":-1:": "👎",
    ]
}
