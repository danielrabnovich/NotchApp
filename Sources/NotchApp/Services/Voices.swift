import CoreML
import FluidAudio
import Foundation

/// The voices on the other side of a call, told apart after it ends: who spoke when in them.aac
/// (speaker diarization with FluidAudio, on this Mac), each "Them" line given its voice, and the
/// voices named from what was said ("thanks, Priya", "this is Sam") or by a voice heard before.
enum Voices {
    /// Who spoke when, and what each voice sounds like (a 256-number print).
    struct Heard {
        struct Turn { let speaker: String; let start: TimeInterval; let end: TimeInterval }
        let turns: [Turn]
        let prints: [String: [Float]]
    }

    enum Progress { case downloading(Double), listening(Double) }

    /// The models (about 21 MB) are fetched once, the first time a call needs them.
    static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp/Models", isDirectory: true)
    }

    /// Who spoke when in a track; nil when it can't tell (no models, no speech, macOS 14).
    static func listen(to url: URL, progress: @escaping @Sendable (Progress) -> Void) async -> Heard? {
        // FluidAudio's own warning: Core ML on macOS 14 can crash in this pipeline (fixed in 15).
        guard #available(macOS 15, *) else { return nil }
        do {
            let config = MLModelConfiguration()
            // The Neural Engine: as quick as the GPU here, at half the memory.
            config.computeUnits = .cpuAndNeuralEngine
            let models = try await OfflineDiarizerModels.load(from: modelsFolder, configuration: config) { p in
                if case .downloading = p.phase { progress(.downloading(p.fractionCompleted)) }
            }
            let diarizer = OfflineDiarizerManager()
            diarizer.initialize(models: models)
            let result = try await diarizer.process(url) { done, total in progress(.listening(Double(done) / Double(max(1, total)))) }
            let turns = result.segments.map { Heard.Turn(speaker: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds)) }
            return turns.isEmpty ? nil : Heard(turns: turns, prints: result.speakerDatabase ?? [:])
        } catch {
            DebugHooks.log("VOICES \(url.lastPathComponent) failed: \(error)")
            return nil
        }
    }

    /// Each "Them" line given the voice it mostly overlaps, numbered in the order they first
    /// speak. Lines no voice covers well stay unmarked.
    static func assign(_ heard: Heard, to lines: [LiveCaptions.Line]) -> (lines: [LiveCaptions.Line], voices: [MeetingAssistant.Voice]) {
        func span(_ line: LiveCaptions.Line) -> (TimeInterval, TimeInterval)? {
            guard line.speaker == .them, let start = line.offset else { return nil }
            return (start, max(line.end ?? start, start + 0.2))
        }
        // Whose turn covers most of each line.
        var who: [String?] = lines.map { line in
            guard let (start, end) = span(line) else { return nil }
            var overlap: [String: TimeInterval] = [:]
            for turn in heard.turns where turn.end > start && turn.start < end {
                overlap[turn.speaker, default: 0] += min(end, turn.end) - max(start, turn.start)
            }
            guard let best = overlap.max(by: { $0.value < $1.value }), best.value >= min(0.5, (end - start) * 0.3) else { return nil }
            return best.key
        }
        // A word or two ("Sure.") the diarizer skipped: the voice of the line said right next to
        // it, else of the turn right next to it.
        for (i, line) in lines.enumerated() where who[i] == nil {
            guard let (start, end) = span(line), end - start < 1.5 else { continue }
            let neighbours = [lines[..<i].lastIndex { span($0) != nil }, lines[(i + 1)...].firstIndex { span($0) != nil }]
                .compactMap { $0 }
                .compactMap { j -> (String, TimeInterval)? in
                    guard let voice = who[j], let (s, e) = span(lines[j]) else { return nil }
                    return (voice, max(0, max(s - end, start - e)))
                }
            if let near = neighbours.min(by: { $0.1 < $1.1 }), near.1 < 0.6 {
                who[i] = near.0
            } else if let turn = heard.turns.min(by: { gap($0, start, end) < gap($1, start, end) }), gap(turn, start, end) < 0.6 {
                who[i] = turn.speaker
            }
        }
        // Numbered in the order they first speak.
        var numbers: [String: Int] = [:]
        var voices: [MeetingAssistant.Voice] = []
        let marked = zip(lines, who).map { line, speaker -> LiveCaptions.Line in
            guard let speaker else { return line }
            if numbers[speaker] == nil {
                numbers[speaker] = voices.count + 1
                voices.append(.init(number: voices.count + 1, print: heard.prints[speaker].map(normalized)))
            }
            var line = line
            line.voice = numbers[speaker]
            return line
        }
        return (marked, voices)
    }

    /// Seconds between a turn and a stretch of the recording (0 when they overlap).
    private static func gap(_ turn: Heard.Turn, _ start: TimeInterval, _ end: TimeInterval) -> TimeInterval {
        max(0, max(turn.start - end, start - turn.end))
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? v.map { $0 / length } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return zip(normalized(a), normalized(b)).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

// MARK: - Names from what was said

/// Names for the voices from the transcript: someone introducing themselves ("this is Sam", "Sam
/// here"), or being spoken to ("thanks, Priya" after Priya spoke; "Priya, can you…" before she
/// does). Only the meeting's attendees count, and only a voice the evidence clearly points at gets
/// a name. Apple's model reads the transcript where it's available; these rules check it, and
/// stand in for it elsewhere.
enum VoiceNames {
    /// The names a voice could be called: each attendee's first name, mapped to how it's shown.
    static func candidates(_ attendees: [String]) -> [String: String] {
        let you = NSFullUserName().split(separator: " ").first.map { String($0).lowercased() }
        var names: [String: String] = [:]
        for person in attendees {
            guard let first = person.split(separator: " ").first.map(String.init), first.count >= 2,
                  first.lowercased() != you else { continue }
            names[first.lowercased()] = first
        }
        return names
    }

    /// Voice number → name, where it's clear.
    static func guess(_ lines: [LiveCaptions.Line], attendees: [String]) async -> [Int: String] {
        let names = candidates(attendees)
        guard !names.isEmpty, lines.contains(where: { $0.voice != nil }) else { return [:] }
        let cues = evidence(lines, names: names)
        var picked = decide(cues)
        if AppleModel.isAvailable, let asked = try? await AppleModel.voiceNames(transcript(lines), names: Array(Set(names.values)).sorted()) {
            for (voice, raw) in asked {
                guard let name = names[raw.lowercased()], picked[voice] == nil,
                      !picked.values.contains(name), cues.against[voice]?.contains(name) != true,
                      lines.contains(where: { $0.voice == voice }) else { continue }
                picked[voice] = name
            }
        }
        return picked
    }

    /// What the lines say about who's who: votes for a voice being someone, and names a voice
    /// can't be (it was talking to them).
    struct Evidence {
        var votes: [Int: [String: Double]] = [:]
        var against: [Int: Set<String>] = [:]
    }

    static func evidence(_ lines: [LiveCaptions.Line], names: [String: String]) -> Evidence {
        var cues = Evidence()
        let alternatives = names.keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        func regex(_ pattern: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern.replacingOccurrences(of: "NAME", with: "(\(alternatives))"), options: [.caseInsensitive])
        }
        // Introducing themselves.
        let intro = regex(#"\b(?:this is|it's|i'm|i am|my name is) NAME\b(?!['’]s)|(?:^|[.!?,]\s*)NAME here\b"#)
        // Answering or thanking the one who just spoke.
        let reply = regex(#"\b(?:thanks|thank you|cheers|sure|yes|yeah|okay|ok|right|good (?:question|point|catch)|great|agreed|exactly|absolutely),? NAME\b"#)
        // Speaking to the next one: a name opening a sentence, then a question or a request.
        let ask = regex(#"(?:^|[.!?]\s+)(?:so,? |and,? |okay,? )?NAME(?:,\s*|\s+)(?:can you|could you|would you|will you|do you|did you|are you|have you|what|how|when|where|why|any|please|go ahead|over to you|you)\b"#)
        let any = regex("\\bNAME\\b")
        func found(_ re: NSRegularExpression?, in said: String) -> [String] {
            guard let re else { return [] }
            let text = said.replacingOccurrences(of: "’", with: "'")
            return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
                (1..<m.numberOfRanges).lazy.compactMap { Range(m.range(at: $0), in: text) }.first.map { String(text[$0]).lowercased() }
            }.compactMap { names[$0] }
        }
        var introduced: [Int: Set<String>] = [:]
        for (i, line) in lines.enumerated() {
            let voice = line.voice
            if let voice {
                // Talking about or to someone: it isn't them (unless they said it's them).
                cues.against[voice, default: []].formUnion(found(any, in: line.text))
                for name in found(intro, in: line.text) {
                    cues.votes[voice, default: [:]][name, default: 0] += 2
                    introduced[voice, default: []].insert(name)
                }
            }
            // The one who spoke just before, and the one who speaks next (another voice, or You).
            let before = lines[..<i].last { $0.speaker != line.speaker || $0.voice != voice }
            let after = lines[(i + 1)...].first { $0.speaker != line.speaker || $0.voice != voice }
            if let other = before?.voice, before?.speaker == .them {
                for name in found(reply, in: line.text) { cues.votes[other, default: [:]][name, default: 0] += 1 }
            }
            if let other = after?.voice, after?.speaker == .them {
                for name in found(ask, in: line.text) { cues.votes[other, default: [:]][name, default: 0] += 1 }
            }
        }
        for (voice, names) in introduced { cues.against[voice]?.subtract(names) }
        return cues
    }

    /// A name for a voice when its votes clearly point one way, the voice never spoke to that
    /// name itself, and no other voice has a better claim to it.
    static func decide(_ cues: Evidence) -> [Int: String] {
        var claims: [(voice: Int, name: String, score: Double)] = []
        for (voice, votes) in cues.votes {
            let ranked = votes.filter { cues.against[voice]?.contains($0.key) != true }.sorted { $0.value > $1.value }
            guard let top = ranked.first else { continue }
            let runnerUp = ranked.dropFirst().first?.value ?? 0
            // One clear cue is enough when nothing points elsewhere; otherwise twice the next.
            guard top.value >= 1, top.value >= runnerUp * 2, top.value > runnerUp else { continue }
            claims.append((voice, top.key, top.value))
        }
        var picked: [Int: String] = [:]
        for claim in claims.sorted(by: { $0.score > $1.score }) where !picked.values.contains(claim.name) {
            // Two voices tied for one name: neither is clear.
            if claims.contains(where: { $0.name == claim.name && $0.voice != claim.voice && $0.score == claim.score }) { continue }
            picked[claim.voice] = claim.name
        }
        return picked
    }

    /// The transcript as the model reads it: voices by number, the user as You.
    static func transcript(_ lines: [LiveCaptions.Line]) -> String {
        lines.compactMap { line in
            if line.speaker == .you { return "You: \(line.text)" }
            return line.voice.map { "Speaker \($0): \(line.text)" }
        }.joined(separator: "\n")
    }
}

// MARK: - Voices heard before

/// What the people the user has named sound like, so a voice can be named in later calls. Each
/// print is the average of the voices the user gave that name (at most the last 12); a new voice
/// is named only when it's very close to one print and clearly closer than to any other.
/// Application Support/NotchApp/Voices.json, on this Mac only; a call's samples go when it's deleted.
@MainActor
final class VoicePrints {
    static let shared = VoicePrints()

    struct Sample: Codable { let meeting: UUID; let voice: Int; let print: [Float] }
    struct Person: Codable { var name: String; var samples: [Sample] }

    /// Cosine similarity a voice needs to be named from a print, and its lead over the next print.
    static let threshold: Float = 0.75
    static let margin: Float = 0.1

    private(set) var people: [Person] = []

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp/Voices.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let people = try? JSONDecoder().decode([Person].self, from: data) {
            self.people = people
        }
    }

    /// The name a print belongs to, when it's clear.
    func match(_ print: [Float]) -> String? {
        let scored = people.map { ($0.name, Voices.cosine(print, Self.average($0.samples))) }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= Self.threshold, best.1 - (scored.dropFirst().first?.1 ?? -1) >= Self.margin else { return nil }
        return best.0
    }

    /// The user named a voice in a call (nil: they took the name away).
    func learn(_ name: String?, print: [Float]?, meeting: UUID, voice: Int) {
        for i in people.indices { people[i].samples.removeAll { $0.meeting == meeting && $0.voice == voice } }
        if let name, let print {
            let sample = Sample(meeting: meeting, voice: voice, print: print)
            if let i = people.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                people[i].samples = Array((people[i].samples + [sample]).suffix(12))
            } else {
                people.append(Person(name: name, samples: [sample]))
            }
        }
        people.removeAll { $0.samples.isEmpty }
        save()
    }

    /// A deleted call's voices.
    func forget(_ meeting: UUID) {
        guard people.contains(where: { $0.samples.contains { $0.meeting == meeting } }) else { return }
        for i in people.indices { people[i].samples.removeAll { $0.meeting == meeting } }
        people.removeAll { $0.samples.isEmpty }
        save()
    }

    private static func average(_ samples: [Sample]) -> [Float] {
        guard let first = samples.first else { return [] }
        var sum = [Float](repeating: 0, count: first.print.count)
        for s in samples where s.print.count == sum.count { for i in sum.indices { sum[i] += s.print[i] } }
        return Voices.normalized(sum)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(people) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}
