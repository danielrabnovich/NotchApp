import AVFoundation
import AppKit
import SwiftUI

/// What a transcribed call is good for: a heads-up when someone says your name while you're in
/// another window, "catch me up" in the middle of it, notes when it ends (a summary, decisions,
/// action items to review into Tasks, a follow-up to send), and every call kept on this Mac, its
/// sound too, to find again from the search bar and play back from any line.
@MainActor
final class MeetingAssistant: ObservableObject {
    static let shared = MeetingAssistant()

    struct Meeting: Codable, Identifiable, Equatable {
        var id = UUID()
        let title: String
        let app: String
        let started: Date
        let ended: Date
        var lines: [LiveCaptions.Line]
        var notes: String?
        /// When its sound begins (lines' offsets count from here); none for calls kept as text only.
        var recorded: Date?
        /// Transcribed again from the recording, after the call.
        var refined: Bool?
        /// The action items, as the model listed them ("Owner: task (when)").
        var actions: [String]?
        /// In a room, on the microphone alone: nobody's marked as who.
        var inPerson: Bool?
        var attendees: [String]?
        /// The other side's voices, told apart after the call (none for calls kept before).
        var voices: [Voice]?

        var transcript: String {
            if inPerson == true { return lines.map(\.text).joined(separator: "\n") }
            return lines.map { "\(label($0)): \($0.text)" }.joined(separator: "\n")
        }

        /// Who said a line: You, the voice's name, "Speaker 2", or Them (one voice, or not told apart).
        func label(_ line: LiveCaptions.Line) -> String {
            guard line.speaker == .them else { return "You" }
            guard let n = line.voice, let voice = voices?.first(where: { $0.number == n }) else { return "Them" }
            if let name = voice.name { return name }
            return (voices?.count ?? 0) > 1 ? "Speaker \(n)" : "Them"
        }

        var minutes: Int { max(1, Int(ended.timeIntervalSince(started) / 60)) }
        var when: String { started.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) }
    }

    /// One of the other side's voices in a call.
    struct Voice: Codable, Equatable {
        let number: Int
        var name: String?
        /// How it got its name: from what was said, from a voice heard before, or by the user.
        var namedBy: NamedBy?
        /// What it sounds like, to know it again in later calls.
        var print: [Float]?

        enum NamedBy: String, Codable { case said, heardBefore, user }
    }

    /// Where a kept call is up to after it ends.
    enum Stage: Equatable {
        /// Listening to the recording again, 0…1.
        case transcribing(Double)
        /// Getting the model that tells voices apart (once), 0…1.
        case downloadingVoices(Double)
        /// Telling the other side's voices apart, 0…1.
        case voices(Double)
        /// The notes so far.
        case writing(String)
    }

    /// Saved calls, newest first.
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var stage: [UUID: Stage] = [:]
    private var call: MeetingMonitor.Call?
    private var recording: MeetingRecording?
    private var askPrompt: UUID?
    private var lastNameAlert = Date.distantPast
    private var pipelines: [UUID: Task<Void, Never>] = [:]
    /// Notes asked for (the rest are written on their own only with a model on this Mac).
    private var wantsNotes: Set<UUID> = []
    private var failures: [UUID: String] = [:]

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A call's sound: Meetings/<id>/them.aac and you.aac.
    static func folder(for id: UUID) -> URL { folder.appendingPathComponent(id.uuidString, isDirectory: true) }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    /// The tracks a meeting has on disk.
    func tracks(_ id: UUID) -> [LiveCaptions.Speaker: URL] {
        var found: [LiveCaptions.Speaker: URL] = [:]
        for side in [LiveCaptions.Speaker.them, .you] {
            let url = MeetingRecording.trackURL(side, in: Self.folder(for: id))
            if FileManager.default.fileExists(atPath: url.path) { found[side] = url }
        }
        return found
    }

    private init() {
        load()
        recover()
    }

    // MARK: - The call

    /// A call started. Recording it is asked first: some places need everyone's consent.
    func callStarted(_ call: MeetingMonitor.Call) {
        self.call = call
        guard AppSettings.shared.transcribeCalls, LiveCaptions.isSupported, !LiveCaptions.shared.recording else { return }
        let prompt = Prompt(icon: "record.circle", tint: .systemRed, title: "Record this call?",
                            detail: "\(call.title): both sides, transcribed and kept on this Mac. Tell the others.",
                            actions: [.init(title: "Record", primary: true) { MeetingAssistant.shared.record() }],
                            dismissTitle: "Not Now")
        askPrompt = prompt.id
        NotchPresenter.shared.offer(prompt, peekFor: 8)
    }

    /// Starts keeping the call that's on, both sides; with no call, a meeting in the room, on the
    /// microphone alone.
    func record() {
        guard LiveCaptions.isSupported, !LiveCaptions.shared.recording else { return }
        if let askPrompt { NotchPresenter.shared.withdraw(askPrompt) }
        askPrompt = nil
        if MeetingMonitor.shared.call == nil { MeetingMonitor.shared.beginInPerson() }
        guard let call = MeetingMonitor.shared.call else { return }
        start(call, tracks: call.inPerson ? [.you] : [.them, .you], listen: call.inPerson ? [.you] : [.them, .you])
    }

    private func start(_ call: MeetingMonitor.Call, tracks: [LiveCaptions.Speaker], listen: [LiveCaptions.Speaker]) {
        self.call = call
        let id = UUID()
        let session = MeetingRecording(id: id, folder: Self.folder(for: id), title: call.title, app: call.app, started: call.started,
                                       sides: tracks, inPerson: call.inPerson, attendees: call.attendees)
        recording = session
        LiveCaptions.shared.startRecording(session, sides: listen, vocabulary: Self.vocabulary(title: call.title, attendees: call.attendees))
        DebugHooks.log("MEETING recording \(id) tracks=\(tracks) listen=\(listen)")
    }

    /// Stops keeping it: an in-person meeting (or one kept past its call) ends there; a call goes on.
    func stopRecording() {
        guard LiveCaptions.shared.recording, let call = MeetingMonitor.shared.call ?? self.call else { return }
        if call.inPerson || call.kept { MeetingMonitor.shared.endCall(); return }
        finish(call, at: Date())
    }

    /// Returns true when it took over the end of the call (there's a recording to make notes from).
    func callEnded(_ call: MeetingMonitor.Call, at end: Date) -> Bool {
        self.call = nil
        if let askPrompt { NotchPresenter.shared.withdraw(askPrompt) }
        askPrompt = nil
        guard LiveCaptions.shared.recording else { return false }
        finish(call, at: end)
        return true
    }

    private func finish(_ call: MeetingMonitor.Call, at end: Date) {
        guard let session = recording else { return }
        recording = nil
        Task {
            let lines = await LiveCaptions.shared.stopRecording()
            guard Self.worthKeeping(lines, length: end.timeIntervalSince(session.start)) else {
                try? FileManager.default.removeItem(at: session.folder)
                return
            }
            let meeting = Meeting(id: session.id, title: call.title, app: call.app, started: call.started, ended: end, lines: lines,
                                  recorded: session.start, inPerson: call.inPerson ? true : nil,
                                  attendees: call.attendees.isEmpty ? nil : call.attendees)
            save(meeting)
            try? FileManager.default.removeItem(at: MeetingRecording.journalURL(in: session.folder))
            process(meeting.id)
            NotchPresenter.shared.offer(Prompt(icon: "waveform.and.magnifyingglass", tint: .systemGreen,
                                               title: "\(call.title) ended",
                                               detail: "\(meeting.minutes) min, recorded on this Mac. Notes and action items?",
                                               actions: [.init(title: "Write Notes", primary: true) {
                                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MeetingAssistant.shared.showNotes(meeting.id) }
                                               }]),
                                        peek: true)
        }
    }

    /// A few words aren't a meeting; two minutes of sound may be, even if the live words missed it.
    private static func worthKeeping(_ lines: [LiveCaptions.Line], length: TimeInterval) -> Bool {
        lines.map(\.text.count).reduce(0, +) > 200 || length >= 120
    }

    /// Calls cut off by a crash or a forced quit: their journal and sound are still there, so
    /// they're kept like any other (and transcribed again from the sound).
    private func recover() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), meeting(id) == nil,
                  let data = try? Data(contentsOf: MeetingRecording.journalURL(in: dir)),
                  let journal = try? decoder.decode(MeetingRecording.Journal.self, from: data) else { continue }
            // It ended about when its sound did.
            let ended = tracks(id).values.compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max()
                ?? journal.recordingStarted
            guard Self.worthKeeping(journal.lines, length: ended.timeIntervalSince(journal.recordingStarted)) else {
                try? fm.removeItem(at: dir)
                continue
            }
            let meeting = Meeting(id: id, title: journal.title, app: journal.app, started: journal.started, ended: ended,
                                  lines: journal.lines, recorded: journal.recordingStarted, inPerson: journal.inPerson,
                                  attendees: journal.attendees)
            save(meeting)
            try? fm.removeItem(at: MeetingRecording.journalURL(in: dir))
            DebugHooks.log("MEETING recovered \(id) lines=\(journal.lines.count)")
            // Once launch has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { MeetingAssistant.shared.process(id) }
        }
    }

    // MARK: - After the call

    /// Transcribes the recording again (finished results are steadier than the live stream's),
    /// then writes the notes: on its own with a model on this Mac, or once they're asked for.
    func process(_ id: UUID, notes asked: Bool = false) {
        if asked { wantsNotes.insert(id) }
        guard pipelines[id] == nil else { return }
        failures[id] = nil
        pipelines[id] = Task(priority: .utility) {
            await refine(id)
            await tellVoicesApart(id)
            if let m = meeting(id), m.notes == nil {
                let ai = AssistantStore.shared.aiAvailable
                if m.lines.isEmpty {
                    failures[id] = "Nothing was heard on this call"
                } else if !ai, wantsNotes.contains(id) {
                    failures[id] = AssistantStore.needsModel
                } else if ai, wantsNotes.contains(id) || !AppSettings.shared.aiProvider.isCloud {
                    await writeNotes(id)
                }
            }
            stage[id] = nil
            pipelines[id] = nil
            wantsNotes.remove(id)
        }
    }

    private func refine(_ id: UUID) async {
        guard let m = meeting(id), m.refined != true, LiveCaptions.isSupported else { return }
        let found = tracks(id)
        guard !found.isEmpty, #available(macOS 26, *) else { return }
        stage[id] = .transcribing(0)
        let vocabulary = Self.vocabulary(title: m.title, attendees: m.attendees ?? [])
        let sides = [LiveCaptions.Speaker.them, .you].filter { found[$0] != nil }
        let began = m.recorded ?? m.started
        var lines: [LiveCaptions.Line] = []
        for (i, side) in sides.enumerated() {
            do {
                let parts = try await SpeechStream.transcribe(file: found[side]!, context: vocabulary) { p in
                    Task { @MainActor in MeetingAssistant.shared.stage[id] = .transcribing((Double(i) + p) / Double(sides.count)) }
                }
                lines += parts.map { LiveCaptions.Line(speaker: side, text: $0.text, at: began.addingTimeInterval($0.start), offset: $0.start, end: $0.end) }
            } catch {
                DebugHooks.log("MEETING refine \(id) \(side) failed: \(error)")
                return // the live transcript stays
            }
        }
        guard var meeting = meeting(id) else { return }
        // Nothing heard at all: the live lines are all there is.
        if !lines.isEmpty {
            meeting.lines = Echo.removed(from: lines.sorted { ($0.offset ?? 0) < ($1.offset ?? 0) })
        }
        meeting.refined = true
        save(meeting)
        DebugHooks.log("MEETING refined \(id) lines=\(meeting.lines.count) (live \(m.lines.count))")
    }

    /// Which of the other side's voices said each line (from them.aac, timed by the second
    /// listen), and their names where it's clear: a voice heard before, then what was said. When
    /// it can't (no model, offline, macOS 14), the lines stay "Them".
    private func tellVoicesApart(_ id: UUID) async {
        guard let m = meeting(id), m.voices == nil, m.inPerson != true, let track = tracks(id)[.them],
              m.lines.contains(where: { $0.speaker == .them && $0.offset != nil }) else { return }
        let began = Date()
        stage[id] = .voices(0)
        let heard = await Voices.listen(to: track) { p in
            Task { @MainActor in
                let assistant = MeetingAssistant.shared
                // Only while it's still this step (a late update mustn't cover the notes).
                switch assistant.stage[id] {
                case .voices?, .downloadingVoices?: break
                default: return
                }
                switch p {
                case .downloading(let f): assistant.stage[id] = .downloadingVoices(f)
                case .listening(let f): assistant.stage[id] = .voices(f)
                }
            }
        }
        guard let heard, var meeting = meeting(id) else { return }
        let assigned = Voices.assign(heard, to: meeting.lines)
        let lines = assigned.lines
        var voices = assigned.voices
        for i in voices.indices {
            if let print = voices[i].print, let name = VoicePrints.shared.match(print), !voices.contains(where: { $0.name == name }) {
                voices[i].name = name
                voices[i].namedBy = .heardBefore
            }
        }
        let open = voices.filter { $0.name == nil }.map(\.number)
        let taken = Set(voices.compactMap(\.name))
        let attendees = (meeting.attendees ?? []).filter { person in !taken.contains { person.lowercased().hasPrefix($0.lowercased()) } }
        for (number, name) in await VoiceNames.guess(lines, attendees: attendees) where open.contains(number) {
            voices[number - 1].name = name
            voices[number - 1].namedBy = .said
        }
        meeting.lines = lines
        meeting.voices = voices
        save(meeting)
        DebugHooks.log(String(format: "MEETING voices %@ %.1fs turns=%d voices=%@", id.uuidString, Date().timeIntervalSince(began),
                              heard.turns.count, voices.map { "\($0.number)=\($0.name ?? "?")(\($0.namedBy?.rawValue ?? "-"))" }.joined(separator: " ")))
    }

    /// The user named one of a call's voices (nil: back to "Speaker 2"). Its lines all follow,
    /// and the name is kept with what the voice sounds like, to know it in later calls.
    func nameVoice(_ number: Int, in id: UUID, as name: String?) {
        guard var meeting = meeting(id), let i = meeting.voices?.firstIndex(where: { $0.number == number }) else { return }
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        meeting.voices?[i].name = name
        meeting.voices?[i].namedBy = name == nil ? nil : .user
        save(meeting)
        VoicePrints.shared.learn(name, print: meeting.voices?[i].print, meeting: id, voice: number)
    }

    private func writeNotes(_ id: UUID) async {
        guard let meeting = meeting(id) else { return }
        stage[id] = .writing("")
        do {
            let written = try await Self.notes(for: meeting) { soFar in
                await MainActor.run { MeetingAssistant.shared.stage[id] = .writing(soFar) }
            }
            setNotes(written.notes, actions: written.actions, for: id)
        } catch {
            failures[id] = error.localizedDescription
            DebugHooks.log("MEETING notes \(id) failed: \(error)")
        }
    }

    /// The notes, once they're written (after the second listen, if it's running).
    func awaitNotes(_ id: UUID) async throws -> String {
        await pipelines[id]?.value
        if let notes = meeting(id)?.notes { return notes }
        throw NSError(domain: "NotchApp", code: 2, userInfo: [NSLocalizedDescriptionKey: failures[id] ?? "Couldn't write the notes"])
    }

    /// Names it should expect to hear: the meeting's, the people in it, the user, the projects
    /// they're working on.
    static func vocabulary(title: String, attendees: [String]) -> [String] {
        let projects = AgentMonitor.shared.sessions.map(\.project)
        // People are mostly called by their first names.
        let people = attendees + [NSFullUserName()]
        let first = people.compactMap { $0.split(separator: " ").first.map(String.init) }.filter { $0.count >= 2 }
        var seen = Set<String>()
        return ([title] + people + first + projects)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("@") && $0.count <= 60 && seen.insert($0.lowercased()).inserted }
            .prefix(60).map { $0 }
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

    private nonisolated static func speakers(_ inPerson: Bool) -> String {
        inPerson ? "an in-person meeting recorded on one microphone, so lines aren't marked by speaker"
                 : "lines marked You are the user; the others are marked by name, as Speaker 1, 2… when their name isn't known, or as Them"
    }

    private static func notesInstructions(inPerson: Bool) -> String { """
    You write meeting notes from a call's transcript (\(speakers(inPerson)); speech-to-text, \
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
            let latest = MeetingAssistant.shared.meeting(id) ?? meeting
            let items = latest.actions ?? Self.actionItems(in: notes)
            guard !items.isEmpty else { return nil }
            return ("Add \(items.count == 1 ? "the action item" : "\(items.count) action items")…", {
                MeetingAssistant.shared.planTasks(items, from: latest)
            })
        }
        if let notes = meeting.notes, pipelines[id] == nil {
            AssistantStore.shared.runCustom(query: meeting.title, title: "Notes · \(meeting.title)", icon: "waveform.and.magnifyingglass",
                                            meeting: id, work: { onText in await onText(notes); return notes }, followUp: followUp)
            return
        }
        process(id, notes: true)
        AssistantStore.shared.runCustom(query: meeting.title, title: "Notes · \(meeting.title)", icon: "waveform.and.magnifyingglass",
                                        stage: "Writing notes", meeting: id, work: { onText in
            let notes = try await MeetingAssistant.shared.awaitNotes(id)
            await onText(notes)
            return notes
        }, followUp: followUp)
    }

    /// The notes for a meeting, and its action items when the model listed them on their own.
    /// Apple's model fills in a form for them (guided generation); the others write Markdown.
    private nonisolated static func notes(for meeting: Meeting,
                                          onText: @escaping @Sendable (String) async -> Void) async throws -> (notes: String, actions: [String]?) {
        let transcript = meeting.transcript
        let inPerson = meeting.inPerson == true
        let header = "Call: \(meeting.title) on \(meeting.app), \(meeting.when), \(meeting.minutes) min.\n\n"
        let instructions = await MainActor.run { notesInstructions(inPerson: inPerson) }
        let fits = await fitsAtOnce(transcript)
        if await AppSettings.shared.aiProvider == .apple, AppleModel.isAvailable {
            let source = fits ? header + transcript
                : header + "Notes on each part of the call, in order:\n\n" + (try await partNotes(transcript, inPerson: inPerson))
            if let form = try? await AppleModel.meetingNotes(source, instructions: instructions) {
                let notes = form.markdown
                await onText(notes)
                return (notes, form.actionItems)
            }
        }
        if fits {
            return (try await OllamaClient.chatStream(system: instructions, user: header + transcript, onText: onText), nil)
        }
        let notes = try await OllamaClient.chat(system: instructions, user: header + "Notes on each part of the call, in order:\n\n"
                                                + (try await partNotes(transcript, inPerson: inPerson)))
        await onText(notes)
        return (notes, nil)
    }

    /// Apple's model holds about 8,000 tokens; the rest take a long call at once.
    private nonisolated static func fitsAtOnce(_ transcript: String) async -> Bool {
        let provider = await AppSettings.shared.aiProvider
        return transcript.count < (provider == .apple ? 10_000 : 40_000)
    }

    /// A long call in pieces: notes on each, for the notes on the notes.
    private nonisolated static func partNotes(_ transcript: String, inPerson: Bool) async throws -> String {
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
            Part \(i + 1) of \(parts.count) of a call's transcript (\(speakers(inPerson))).\(await MainActor.run { who }) Write terse notes: \
            what was discussed, decisions, and action items with owner and when. Nothing invented.
            """, user: part)
            partNotes.append("Part \(i + 1):\n\(note)")
        }
        return partNotes.joined(separator: "\n\n")
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

    /// For notchdebug: a call made of a sound file. With `play`, the file plays through the Mac's
    /// speakers and the real system-audio tap hears it; without, it's fed straight in as the
    /// other side. The microphone isn't used either way. `nd call 0` ends it.
    func debugRecordFile(_ url: URL, play: Bool) {
        guard !LiveCaptions.shared.recording else { return }
        MeetingMonitor.shared.debugSimulate(true, minutes: 0)
        guard let call = MeetingMonitor.shared.call else { return }
        start(call, tracks: [.them], listen: play ? [.them] : [])
        if play {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Self.debugPlayer = try? AVAudioPlayer(contentsOf: url)
                Self.debugPlayer?.volume = 0.3
                Self.debugPlayer?.play()
            }
        } else {
            LiveCaptions.shared.debugFeed(url)
        }
    }

    private static var debugPlayer: AVAudioPlayer?

    /// For notchdebug: a kept call as it was right after it ended (not yet transcribed again, no
    /// notes), then its notes opened, to watch the whole way there.
    func debugRedo(_ id: UUID) {
        guard var m = meeting(id) else { return }
        m.refined = nil
        m.voices = nil
        m.notes = nil
        m.actions = nil
        save(m)
        showNotes(id)
    }

    /// For notchdebug: a kept call's voices, and who said each line.
    func debugVoices(_ id: UUID) {
        guard let m = meeting(id) else { return }
        let voices = (m.voices ?? []).map { "\($0.number)=\($0.name ?? "-")(\($0.namedBy?.rawValue ?? "-"), print \($0.print?.count ?? 0))" }
        DebugHooks.log("VOICES \(id) \(m.voices == nil ? "none" : voices.joined(separator: " ")) prints=\(VoicePrints.shared.people.map { "\($0.name)×\($0.samples.count)" })")
        for line in m.lines {
            DebugHooks.log(String(format: "  %@ [%.1f-%.1f] %@: %@", line.voice.map(String.init) ?? "-", line.offset ?? -1, line.end ?? -1, m.label(line), String(line.text.prefix(70))))
        }
    }

    /// For notchdebug: who was invited, as the calendar would have said.
    func debugAttendees(_ id: UUID, _ names: [String]) {
        guard var m = meeting(id) else { return }
        m.attendees = names
        save(m)
    }

    func debugLog() {
        for m in meetings.prefix(5) {
            let lines = m.lines.prefix(6).map { "[\($0.speaker.rawValue) \($0.offset.map { String(format: "%.1f", $0) } ?? "-")] \($0.text.prefix(60))" }
            DebugHooks.log("MEETING \(m.id) \(m.title) refined=\(m.refined ?? false) notes=\(m.notes != nil) actions=\(m.actions ?? []) tracks=\(tracks(m.id).keys.map(\.rawValue)) stage=\(String(describing: stage[m.id])) lines=\(m.lines.count) \(lines)")
        }
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

    /// Its transcript, notes and sound.
    func delete(_ id: UUID) {
        pipelines[id]?.cancel()
        if MeetingPlayer.shared.meeting == id { MeetingPlayer.shared.stop() }
        meetings.removeAll { $0.id == id }
        VoicePrints.shared.forget(id)
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: Self.folder(for: id))
    }

    private func setNotes(_ notes: String, actions: [String]? = nil, for id: UUID) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[i].notes = notes
        meetings[i].actions = actions
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
