import AppKit
import SwiftUI

/// What a transcribed call is good for: a heads-up when someone says your name while you're in
/// another window, "catch me up" in the middle of it, notes when it ends (a summary, decisions,
/// action items to review into Tasks, a follow-up to send), and every call kept on this Mac to
/// find again from the search bar.
@MainActor
final class MeetingAssistant: ObservableObject {
    static let shared = MeetingAssistant()

    struct Meeting: Codable, Identifiable, Equatable {
        var id = UUID()
        let title: String
        let app: String
        let started: Date
        let ended: Date
        let lines: [LiveCaptions.Line]
        var notes: String?

        var transcript: String { lines.map { "\($0.speaker == .you ? "You" : "Them"): \($0.text)" }.joined(separator: "\n") }
        var minutes: Int { max(1, Int(ended.timeIntervalSince(started) / 60)) }
        var when: String { started.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) }
    }

    /// Saved calls, newest first.
    @Published private(set) var meetings: [Meeting] = []
    private var call: MeetingMonitor.Call?
    private var lastNameAlert = Date.distantPast

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() { load() }

    // MARK: - The call

    func callStarted(_ call: MeetingMonitor.Call) {
        self.call = call
        guard AppSettings.shared.transcribeCalls, LiveCaptions.isSupported else { return }
        LiveCaptions.shared.startRecording()
    }

    /// Returns true when it took over the end of the call (there's a transcript to make notes from).
    func callEnded(_ call: MeetingMonitor.Call, at end: Date) -> Bool {
        self.call = nil
        guard LiveCaptions.shared.recording else { return false }
        Task {
            let lines = await LiveCaptions.shared.stopRecording()
            // A few words aren't a meeting.
            guard lines.map(\.text.count).reduce(0, +) > 200 else { return }
            let meeting = Meeting(title: call.title, app: call.app, started: call.started, ended: end, lines: lines)
            save(meeting)
            NotchPresenter.shared.offer(Prompt(icon: "waveform.and.magnifyingglass", tint: .systemGreen,
                                               title: "\(call.title) ended",
                                               detail: "\(meeting.minutes) min, transcribed on this Mac. Notes and action items?",
                                               actions: [.init(title: "Write Notes", primary: true) {
                                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MeetingAssistant.shared.showNotes(meeting.id) }
                                               }]),
                                        peek: true)
        }
        return true
    }

    // MARK: - Your name

    /// The user's first name: what "they're talking to you" sounds like.
    private static let firstName: String? = NSFullUserName().split(separator: " ").first.map(String.init).flatMap { $0.count >= 2 ? $0 : nil }

    /// Someone on the call said your name while you're looking at something else: a Banner, with
    /// what they said (at most one a minute).
    func heard(_ line: LiveCaptions.Line) {
        guard LiveCaptions.shared.recording, let name = Self.firstName,
              line.text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: [.regularExpression, .caseInsensitive]) != nil,
              Date().timeIntervalSince(lastNameAlert) > 60 else { return }
        // In the call's own window, you heard it yourself.
        if let id = call?.bundleID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id { return }
        lastNameAlert = Date()
        let question = line.text.hasSuffix("?")
        ActivityCenter.shared.show(.notice(title: question ? "\(name), a question for you" : "Someone said your name",
                                           detail: "“\(line.text.suffix(110))”", icon: "person.wave.2.fill", tone: .info), for: 6)
    }

    // MARK: - Catch me up

    var inCall: Bool { LiveCaptions.shared.recording }

    /// "Catch me up", "what did they say about pricing": answered from the call so far.
    func catchUp(_ question: String) {
        let transcript = LiveCaptions.shared.transcript
        guard !transcript.isEmpty else {
            ActivityCenter.shared.show(.notice(title: "Nothing said yet", detail: "The call's transcript is empty so far", icon: "waveform", tone: .info), for: 2.5)
            return
        }
        let recent = String(transcript.suffix(30_000))
        let ask = question.lowercased().contains("catch me up") || question.lowercased() == "catch up"
            ? "Catch me up: what's been discussed, most recent last, and anything that's waiting on me. Short bullets."
            : question
        let system = """
        You help someone in a call who looked away for a moment. Answer from the transcript only (lines marked You are them; \
        Them is everyone else).\(Self.who) Be brief and concrete; quote short phrases when it helps. If the transcript doesn't say, say so.
        """
        AssistantStore.shared.runCustom(query: question, title: "From the call", icon: "waveform", stage: "Reading the call") { onText in
            try await OllamaClient.chatStream(system: system, user: "Transcript so far:\n\(recent)\n\nQuestion: \(ask)", onText: onText)
        }
    }

    // MARK: - Notes

    /// "The user is Phil": so "Phil, can you…" is theirs, and "get it to Phil" isn't.
    private static var who: String { firstName.map { " The user's name is \($0)." } ?? "" }

    private static var notesInstructions: String { """
    You write meeting notes from a call's transcript (lines marked You are the user; Them is everyone else; speech-to-text, \
    so fix obvious mishearings).\(who) Markdown, in this order:
    **Summary**: two or three sentences.
    **Decisions**: bullets, or "None".
    **Action items**: bullets as "Owner: task (when)"; "You" for the user's own; leave out when if none was said.
    **Follow-up**: a short, friendly email the user could send to everyone afterwards.
    Nothing else; don't invent anything that wasn't said.
    """ }

    func showNotes(_ id: UUID) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        NotchPresenter.shared.primary?.open(tab: .ask, takeKeyboard: false, reason: .click)
        let followUp: @MainActor (String) -> (title: String, run: () -> Void)? = { notes in
            let items = Self.actionItems(in: notes)
            guard !items.isEmpty else { return nil }
            return ("Add \(items.count == 1 ? "the action item" : "\(items.count) action items")…", {
                MeetingAssistant.shared.planTasks(items, from: meeting)
            })
        }
        if let notes = meeting.notes {
            AssistantStore.shared.runCustom(query: meeting.title, title: "Notes · \(meeting.title)", icon: "waveform.and.magnifyingglass",
                                            work: { onText in await onText(notes); return notes }, followUp: followUp)
            return
        }
        let transcript = meeting.transcript
        let header = "Call: \(meeting.title) on \(meeting.app), \(meeting.when), \(meeting.minutes) min.\n\n"
        AssistantStore.shared.runCustom(query: meeting.title, title: "Notes · \(meeting.title)", icon: "waveform.and.magnifyingglass",
                                        stage: "Writing notes", work: { onText in
            let notes: String
            if await Self.fitsAtOnce(transcript) {
                notes = try await OllamaClient.chatStream(system: Self.notesInstructions, user: header + transcript, onText: onText)
            } else {
                notes = try await Self.chunkedNotes(header: header, transcript: transcript)
                await onText(notes)
            }
            await MainActor.run { MeetingAssistant.shared.setNotes(notes, for: meeting.id) }
            return notes
        }, followUp: followUp)
    }

    /// Apple's model holds about 8,000 tokens; the rest take a long call at once.
    private static func fitsAtOnce(_ transcript: String) async -> Bool {
        let provider = await AppSettings.shared.aiProvider
        return transcript.count < (provider == .apple ? 10_000 : 40_000)
    }

    /// A long call in pieces: notes on each, then the notes on the notes.
    private nonisolated static func chunkedNotes(header: String, transcript: String) async throws -> String {
        let piece = await AppSettings.shared.aiProvider == .apple ? 9_000 : 36_000
        var parts: [String] = []
        var current = ""
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            if current.count + line.count > piece, !current.isEmpty { parts.append(current); current = "" }
            current += line + "\n"
        }
        if !current.isEmpty { parts.append(current) }
        var partNotes: [String] = []
        for (i, part) in parts.enumerated() {
            let note = try await OllamaClient.chat(system: """
            Part \(i + 1) of \(parts.count) of a call's transcript (You is the user; Them everyone else).\(await MainActor.run { who }) Write terse notes: \
            what was discussed, decisions, and action items with owner and when. Nothing invented.
            """, user: part)
            partNotes.append("Part \(i + 1):\n\(note)")
        }
        return try await OllamaClient.chat(system: notesInstructions, user: header + "Notes on each part of the call, in order:\n\n" + partNotes.joined(separator: "\n\n"))
    }

    /// "You: send the checklist (today)" stays the user's; "Priya: get the copy to Phil (Wednesday)"
    /// becomes something to chase: "Follow up with Priya: get the copy to Phil (Wednesday)".
    static func taskWording(_ item: String) -> String {
        let plain = item.replacingOccurrences(of: "**", with: "")
        guard let colon = plain.firstIndex(of: ":") else { return plain }
        let owner = plain[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = plain[plain.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, owner.split(separator: " ").count <= 3, !rest.isEmpty else { return plain }
        let mine = ["you", "me", "i", firstName?.lowercased() ?? "you"].contains(owner.lowercased())
        return mine ? rest : "Follow up with \(owner): \(rest)"
    }

    /// The bullets under **Action items**.
    static func actionItems(in notes: String) -> [String] {
        var items: [String] = []
        var inside = false
        for raw in notes.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.contains("action items") { inside = true; continue }
            if inside, line.hasPrefix("**") || line.hasPrefix("#") { break }
            if inside, line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("•") {
                let item = line.drop { "-*• ".contains($0) }.trimmingCharacters(in: .whitespaces)
                if !item.isEmpty, item.lowercased() != "none" { items.append(item) }
            }
        }
        return items
    }

    /// The action items as tasks to review before adding, worded as the notes have them: the
    /// user's own as they are, everyone else's as something to follow up on. Due times ("by
    /// Wednesday morning") are read the way the search bar reads them.
    private func planTasks(_ items: [String], from meeting: Meeting) {
        let commands = items.map(Self.taskWording).map { item in
            CommandParser.addTasks([item.trimmingCharacters(in: CharacterSet(charactersIn: ". "))])
        }
        let plan = CommandPlanner.Plan(summary: "Action items from \(meeting.title)", commands: commands)
        AssistantStore.shared.present(plan: plan, query: "Action items · \(meeting.title)")
    }

    /// For notchdebug: a short call's transcript, kept and written up, without a call.
    func debugMeeting() {
        let said: [(LiveCaptions.Speaker, String)] = [
            (.them, "Okay, let's get started. The main thing today is the pricing page launch."),
            (.you, "Right. I finished the new layout yesterday, it just needs copy."),
            (.them, "Great. Priya, can you get the copy to Phil by Wednesday?"),
            (.them, "Yes, I'll have the copy done Wednesday morning."),
            (.them, "And we decided to drop the monthly plan and keep annual only, correct?"),
            (.you, "Yes, annual only. I'll update the checkout to match by Thursday."),
            (.them, "Perfect. Let's ship on Friday then. Phil, can you also send the launch checklist to the team today?"),
            (.you, "Sure, I'll send it this afternoon."),
            (.them, "Last thing, we should book a retro for next Tuesday at two."),
        ]
        let start = Date().addingTimeInterval(-25 * 60)
        let lines = said.enumerated().map { i, s in LiveCaptions.Line(speaker: s.0, text: s.1, at: start.addingTimeInterval(Double(i) * 120)) }
        let meeting = Meeting(title: "Pricing launch sync", app: "Zoom", started: start, ended: Date(), lines: lines)
        save(meeting)
        showNotes(meeting.id)
    }

    // MARK: - Kept calls

    /// Calls whose title or words match, newest first.
    func search(_ query: String, limit: Int) -> [Meeting] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 3 }
        guard !words.isEmpty else { return Array(meetings.prefix(limit)) }
        return meetings.filter { m in
            let haystack = (m.title + " " + (m.notes ?? "") + " " + m.transcript).lowercased()
            return words.allSatisfy(haystack.contains)
        }.prefix(limit).map { $0 }
    }

    func delete(_ id: UUID) {
        meetings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(id.uuidString).json"))
    }

    private func setNotes(_ notes: String, for id: UUID) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[i].notes = notes
        save(meetings[i])
    }

    private func save(_ meeting: Meeting) {
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[i] = meeting } else { meetings.insert(meeting, at: 0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(meeting) {
            try? data.write(to: Self.folder.appendingPathComponent("\(meeting.id.uuidString).json"), options: .atomic)
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        meetings = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
    }
}
