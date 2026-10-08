import Foundation

/// An answer from the app's own notes and tasks.
struct NotesAnswer: Equatable, Sendable {
    struct Line: Equatable, Sendable, Identifiable {
        var id = UUID()
        var text: String
        /// Set for a task (so it can be ticked off); nil for a line of the Notes scratchpad.
        var task: UUID?
        var due: Date?
    }

    var headline: String
    var detail: String?
    var lines: [Line] = []
}

/// "What's in my notes", "what did I write about the palette", "my tasks about the launch": answered
/// from the Notes scratchpad and the open tasks before anything else is searched. With a model the
/// question is answered from them; without one, matching lines are listed.
@MainActor
enum NotesQuery {
    static func answer(_ question: String, useAI: Bool) async -> NotesAnswer {
        let corpus = gather()
        guard !corpus.isEmpty else {
            return NotesAnswer(headline: "Nothing in your notes yet",
                               detail: "Jot something down in Notes, or type “note …” here.")
        }
        let words = keywords(question)
        let matching = words.isEmpty ? corpus : corpus.filter { line in
            let tokens = tokenize(line.text)
            return words.contains { word in tokens.contains { $0.hasPrefix(word) } }
        }

        if useAI, let smart = try? await ask(question, corpus: corpus) { return smart }

        let notes = corpus.filter { $0.task == nil }.count, tasks = corpus.count - notes
        if words.isEmpty {
            return NotesAnswer(headline: summary(notes: notes, tasks: tasks), lines: corpus)
        }
        return matching.isEmpty
            ? NotesAnswer(headline: "Nothing about “\(words.joined(separator: " "))” in your notes")
            : NotesAnswer(headline: "\(matching.count) match\(matching.count == 1 ? "" : "es") in your notes", lines: matching)
    }

    /// Lines of the scratchpad, then the open tasks.
    private static func gather() -> [NotesAnswer.Line] {
        let notes = ScratchpadStore.shared.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { NotesAnswer.Line(text: $0) }
        let tasks = TaskStore.shared.open.map { NotesAnswer.Line(text: $0.title, task: $0.id, due: $0.due) }
        return notes + tasks
    }

    private static func ask(_ question: String, corpus: [NotesAnswer.Line]) async throws -> NotesAnswer {
        let shown = Array(corpus.prefix(120))
        let list = shown.enumerated().map { i, line in
            let due = line.due.map { " (due \($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
            return "[\(i)] \(line.task == nil ? "note" : "task"): \(line.text.prefix(240))\(due)"
        }.joined(separator: "\n")
        let system = """
        You answer questions about the user's own notes and to-do list, using ONLY the numbered lines below. \
        Today is \(Date().formatted(date: .complete, time: .omitted)).
        If they ask what's in their notes or tasks, sum it up in a sentence. If they ask about something specific, \
        answer it from the lines (quote codes, numbers and names exactly). If nothing covers it, say so plainly.
        Reply with JSON only: {"answer": "one or two short sentences", "lines": [indices of the lines that answer it, most relevant first]}
        """
        let obj = try await OllamaClient.chatJSON(system: system, user: "Question: \(question)\n\nLines:\n\(list)")
        guard let answer = (obj["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
            throw OllamaClient.OllamaError(message: "No answer")
        }
        var seen = Set<Int>()
        let lines = (obj["lines"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            .filter { shown.indices.contains($0) && seen.insert($0).inserted }
            .map { shown[$0] }
        let notes = corpus.filter { $0.task == nil }.count
        return NotesAnswer(headline: answer, detail: summary(notes: notes, tasks: corpus.count - notes), lines: lines)
    }

    private static func summary(notes: Int, tasks: Int) -> String {
        [notes > 0 ? "\(notes) line\(notes == 1 ? "" : "s") of notes" : nil,
         tasks > 0 ? "\(tasks) open task\(tasks == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// What the question is about, without the "what's in my notes" framing.
    private static func keywords(_ question: String) -> [String] {
        let filler: Set<String> = ["what", "whats", "s", "is", "are", "in", "on", "my", "the", "a", "an", "of", "about", "notes", "note",
                                   "tasks", "task", "todo", "todos", "to", "do", "list", "show", "me", "did", "i", "write", "wrote",
                                   "down", "jot", "jotted", "have", "any", "there", "anything", "scratchpad", "find", "where", "was",
                                   "that", "for", "with", "and"]
        return tokenize(question).filter { $0.count > 1 && !filler.contains($0) }
    }
}
