import Foundation

/// How well what's typed fits a name, 0–100, the way a launcher reads it: "lms" finds LM Studio,
/// "vsc" Visual Studio Code, "ft" FaceTime, "studio" LM Studio, "spotfy" Spotify.
///
/// The tiers callers lean on: 100 the whole name, 85 its start (spaces aside), 80 the starts of
/// its words in order ("vsc", "gchr"), 70 a later word's start, 65 word starts with a word left
/// out, 62–64 its start with a slip of the finger, 60 two initials, 45 anywhere inside it, and
/// under 45 its letters in order.
public enum FuzzyMatch {
    /// A name split up once, for lists scored on every keystroke.
    public struct Name: Equatable, Sendable {
        let full: String
        let parts: [String]
        let compact: String

        public init(_ name: String) {
            full = FuzzyMatch.fold(name)
            parts = FuzzyMatch.words(name)
            compact = parts.joined()
        }
    }

    public static func score(_ name: String, _ query: String) -> Int { score(Name(name), query) }

    public static func score(_ name: Name, _ query: String) -> Int {
        let q = fold(query).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let (full, parts, compact) = (name.full, name.parts, name.compact)
        if full == q { return 100 }
        let qCompact = String(q.filter { !isSeparator($0) })
        guard !qCompact.isEmpty, !compact.isEmpty else { return 0 }
        if compact == qCompact { return 98 }
        if full.hasPrefix(q) || compact.hasPrefix(qCompact) { return 85 }
        // Word starts, in order, each a piece of what's typed: "lms" → LM Studio, "gchr" → Google Chrome.
        let fromStart = parts.count > 1 && qCompact.count <= 24 ? chunked(Array(qCompact), parts.map(Array.init)) : nil
        if fromStart == true { return qCompact.count >= 3 ? 80 : 60 }
        // What's typed starts a later word, or runs on from one ("studio", "studiocode").
        for i in parts.indices.dropFirst() where parts[i...].joined().hasPrefix(qCompact) { return 70 }
        // Word starts again, after a word left out ("pp" → Adobe Premiere Pro).
        if fromStart == false, qCompact.count >= 3 { return 65 }
        if q.count >= 3, full.contains(q) || compact.contains(qCompact) { return 45 }
        // A slip: one letter wrong, missing, extra or swapped (two in long names).
        if qCompact.count >= 5 {
            let allowed = qCompact.count >= 9 ? 2 : 1
            // The whole name with a slip beats the start of a longer one ("spotfy": Spotify, then SpotBye).
            if typoPrefix(qCompact, compact, allowed) { return distance(Array(qCompact), Array(compact)) <= allowed ? 64 : 62 }
            for i in parts.indices.dropFirst() where typoPrefix(qCompact, parts[i...].joined(), allowed) { return 45 }
        }
        // Letters in order, more for each that starts a word.
        guard qCompact.count >= 3 else { return 0 }
        let starts = Set(parts.indices.map { i in parts[..<i].reduce(0) { $0 + $1.count } })
        let letters = Array(compact)
        var at = 0, hitStarts = 0
        for c in qCompact {
            guard let i = letters[at...].firstIndex(of: c) else { return 0 }
            if starts.contains(i) { hitStarts += 1 }
            at = i + 1
        }
        return 20 + 20 * hitStarts / qCompact.count
    }

    /// The name's words, lowercased: split at spaces and punctuation, where a capital starts a
    /// word ("FaceTime", "iTerm", "LMStudio" → lm, studio) and where letters meet digits.
    public static func words(_ name: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(name)
        for (i, c) in chars.enumerated() {
            if isSeparator(c) {
                if !current.isEmpty { out.append(current); current = "" }
                continue
            }
            if let prev = current.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let camel = prev.isLowercase && c.isUppercase
                let acronymEnd = prev.isUppercase && c.isUppercase && (next?.isLowercase ?? false)
                let digits = prev.isNumber != c.isNumber && (prev.isLetter || c.isLetter)
                if camel || acronymEnd || digits { out.append(current); current = "" }
            }
            current.append(c)
        }
        if !current.isEmpty { out.append(current) }
        return out.map(fold).filter { !$0.isEmpty }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || "-._+&()/:,'’".contains(c)
    }

    /// Splits `q` into pieces that each start a word, the words in order: nil when it can't be,
    /// true when it can without skipping a word (the first piece starting the name).
    private static func chunked(_ q: [Character], _ words: [[Character]]) -> Bool? {
        func go(_ qi: Int, _ wi: Int, _ skipped: Bool) -> Bool? {
            if qi == q.count { return !skipped }
            guard wi < words.count else { return nil }
            var best: Bool?
            let word = words[wi]
            var k = 0
            while k < word.count, qi + k < q.count, word[k] == q[qi + k] { k += 1 }
            // Longest piece first: "lmstudio" takes "lm" from LM, not "l".
            while k > 0 {
                if let r = go(qi + k, wi + 1, skipped) {
                    if r { return true }
                    best = false
                }
                k -= 1
            }
            if let r = go(qi, wi + 1, true), best == nil { best = r }
            return best
        }
        return go(0, 0, false)
    }

    /// `q` against the start of `s` (as long as `q`, give or take one), within `allowed` edits.
    private static func typoPrefix(_ q: String, _ s: String, _ allowed: Int) -> Bool {
        let a = Array(q), b = Array(s)
        for len in [a.count, a.count - 1, a.count + 1] where len > 0 && len <= b.count {
            if distance(a, Array(b[..<len])) <= allowed { return true }
        }
        return false
    }

    /// Edits between two words, a swap of neighbours counting as one.
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in stride(from: 1, through: a.count, by: 1) {
            for j in stride(from: 1, through: b.count, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }
}
