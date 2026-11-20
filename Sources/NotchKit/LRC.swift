import Foundation

/// Time-synced lyrics in the LRC format LRCLIB serves: "[01:02.34] words" per line.
public enum LRC {
    public struct Line: Equatable, Sendable {
        public let time: Double
        public let text: String
        public init(time: Double, text: String) { self.time = time; self.text = text }
    }

    /// Every stamped line, in time order; a line may carry several stamps (a repeated chorus).
    /// Tags like "[ar: …]" and unstamped lines are skipped.
    public static func parse(_ lrc: String) -> [Line] {
        var lines: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let parts = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) { stamps.append(m * 60 + s) }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            lines += stamps.map { Line(time: $0, text: text) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// The line being sung at `time` and how far through it the song is (0…1): up to the next
    /// line, or for the last one, four seconds on. Nil before the first line.
    public static func position(in lines: [Line], at time: Double) -> (index: Int, progress: Double)? {
        guard let i = lines.lastIndex(where: { $0.time <= time }) else { return nil }
        let end = i + 1 < lines.count ? lines[i + 1].time : lines[i].time + 4
        let span = max(0.3, end - lines[i].time)
        return (i, min(1, max(0, (time - lines[i].time) / span)))
    }
}
