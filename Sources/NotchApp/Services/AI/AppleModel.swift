import Foundation
// Weakly linked: the framework is only there from macOS 26, and the app runs on 14. Building it
// needs the macOS 26 SDK; with an older one (Command Line Tools on macOS 15) the model is simply
// unavailable.
#if canImport(FoundationModels)
@_weakLinked import FoundationModels
#endif

/// Apple's own on-device model (Apple Intelligence): no download, no key, nothing leaves the Mac.
/// It reads text only, and holds about 8,000 tokens in all, so long input is cut to fit (and cut
/// again if the model still says it's too long); work on longer text, a meeting's transcript,
/// goes through `summarize(_:instructions:)` in chunks.
enum AppleModel {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { AppleModel.unavailableReason ?? "Apple Intelligence isn't available" }
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return false }
        return Engine.isAvailable
        #else
        return false
        #endif
    }

    /// Why it can't be used, in a line for Settings; nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return "Needs macOS 26 or later" }
        return Engine.unavailableReason
        #else
        return "Needs macOS 26 or later"
        #endif
    }

    /// Characters of input that fit with room for the instructions and the reply (~3.5 per token).
    static let inputBudget = 14_000

    static func chat(system: String, user: String, json: Bool = false, temperature: Double = 0.2) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw Unavailable() }
        let instructions = json ? system + "\nReply with ONLY the JSON object: no prose, no code fences." : system
        return try await fitting(user) { try await Engine.respond(instructions: instructions, text: $0, temperature: temperature) }
        #else
        throw Unavailable()
        #endif
    }

    static func stream(system: String, user: String, temperature: Double = 0.3,
                       onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw Unavailable() }
        return try await fitting(user) { try await Engine.stream(instructions: system, text: $0, temperature: temperature, onText: onText) }
        #else
        throw Unavailable()
        #endif
    }

    /// A meeting's notes as a filled-in form (guided generation), so the action items come out as
    /// items rather than lines to pick out of prose.
    struct MeetingNotes {
        struct Item { let owner: String; let task: String; let when: String }
        let summary: String
        let decisions: [String]
        let items: [Item]
        let followUp: String

        /// "Owner: task (when)", as the review into Tasks reads them.
        var actionItems: [String] {
            items.map { item in
                let owner = item.owner.trimmingCharacters(in: .whitespaces)
                let when = item.when.trimmingCharacters(in: .whitespaces)
                return (owner.isEmpty ? "" : owner + ": ") + item.task + (when.isEmpty ? "" : " (\(when))")
            }
        }

        /// The same Markdown the other models write.
        var markdown: String {
            let decided = decisions.isEmpty ? "None" : decisions.map { "- \($0)" }.joined(separator: "\n")
            let actions = actionItems.isEmpty ? "None" : actionItems.map { "- \($0)" }.joined(separator: "\n")
            return "**Summary**: \(summary)\n\n**Decisions**:\n\(decided)\n\n**Action items**:\n\(actions)\n\n**Follow-up**:\n\(followUp)"
        }
    }

    static func meetingNotes(_ text: String, instructions: String) async throws -> MeetingNotes {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw Unavailable() }
        return try await fitting(text) { try await Engine.meetingNotes(instructions: instructions, text: $0) }
        #else
        throw Unavailable()
        #endif
    }

    /// Runs `body` on the text cut to the budget; if the model still finds it too long, on half as much.
    private static func fitting<T>(_ user: String, _ body: (String) async throws -> T) async throws -> T {
        var text = user.count > inputBudget ? String(user.prefix(inputBudget)) + "\n[…cut to fit]" : user
        for _ in 0..<3 {
            do {
                return try await body(text)
            } catch where "\(error)".contains("context size") {
                text = String(text.prefix(text.count / 2)) + "\n[…cut to fit]"
            }
        }
        return try await body(text)
    }

    /// Long text (a meeting's transcript) in pieces that fit: each piece noted with the task in
    /// mind, then the notes put together the same way, as many rounds as it takes.
    static func summarize(_ text: String, instructions: String) async throws -> String {
        let piece = 10_000
        guard text.count > piece else { return try await chat(system: instructions, user: text) }
        var parts: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            // Break at a line, not mid-sentence.
            var end = rest.index(rest.startIndex, offsetBy: min(piece, rest.count))
            if end < rest.endIndex, let newline = rest[..<end].lastIndex(of: "\n"), rest.distance(from: rest.startIndex, to: newline) > piece / 2 {
                end = rest.index(after: newline)
            }
            parts.append(String(rest[..<end]))
            rest = rest[end...]
        }
        var notes: [String] = []
        for (i, part) in parts.enumerated() {
            notes.append(try await chat(system: "Take notes on part \(i + 1) of \(parts.count) of a longer text: everything that matters for this task, briefly.\nThe task: \(instructions)",
                                        user: part))
        }
        return try await summarize(notes.joined(separator: "\n\n"), instructions: instructions)
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
private enum Engine {
    /// Lenient guardrails: summarizing or rewriting what's on screen trips the strict ones on ordinary text.
    static var model: SystemLanguageModel { SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations) }

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings"
        case .unavailable(.modelNotReady): "Apple Intelligence is still getting ready"
        case .unavailable: "Apple Intelligence isn't available"
        }
    }

    static func respond(instructions: String, text: String, temperature: Double) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(to: text, options: GenerationOptions(temperature: temperature)).content
    }

    @Generable
    struct NotesForm {
        @Guide(description: "Two or three sentences: what the call was about and where it ended up.")
        let summary: String
        @Guide(description: "Each decision that was made, one short sentence each. Empty if none were made.")
        let decisions: [String]
        @Guide(description: "Each thing someone said they'd do. Empty if nobody committed to anything.")
        let actionItems: [ActionItem]
        @Guide(description: "A short, friendly follow-up email the user could send to everyone afterwards.")
        let followUp: String
    }

    @Generable
    struct ActionItem {
        @Guide(description: "Who will do it: \"You\" for the user, otherwise the person's name as said.")
        let owner: String
        @Guide(description: "What they'll do, as a short task starting with a verb.")
        let task: String
        @Guide(description: "When it's due as it was said (\"Wednesday morning\", \"today\"), or empty if no time was said.")
        let when: String
    }

    static func meetingNotes(instructions: String, text: String) async throws -> AppleModel.MeetingNotes {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let form = try await session.respond(to: text, generating: NotesForm.self, options: GenerationOptions(temperature: 0.2)).content
        return AppleModel.MeetingNotes(summary: form.summary, decisions: form.decisions,
                                       items: form.actionItems.map { .init(owner: $0.owner, task: $0.task, when: $0.when) },
                                       followUp: form.followUp)
    }

    static func stream(instructions: String, text: String, temperature: Double,
                       onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        var latest = ""
        var lastEmit = Date.distantPast
        for try await snapshot in session.streamResponse(to: text, options: GenerationOptions(temperature: temperature)) {
            try Task.checkCancellation()
            latest = snapshot.content
            if Date().timeIntervalSince(lastEmit) > 0.05 {
                lastEmit = Date()
                await onText(latest)
            }
        }
        let final = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        await onText(final)
        return final
    }
}
#endif
