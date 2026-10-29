import AppKit
import ScreenCaptureKit
import Vision

/// Answers a question about what's on screen ("what's the right answer to this question",
/// "explain this error"): a silent capture of the window in front (in memory only, never saved),
/// its text as the app reports it (or read with Vision), then the local model looks at both. When it needs
/// facts it doesn't have, it writes a web query and the answer comes from the web instead. Only
/// that query leaves the Mac; the picture never does.
enum ScreenQuestion {
    /// A question already asked about the same capture, so a follow-up ("and the second one?") makes sense.
    struct Exchange: Sendable {
        let question: String
        let answer: String
    }

    static func answer(_ question: String, context: ScreenContext, history: [Exchange] = [],
                       progress: @escaping @Sendable (String) async -> Void,
                       partial: @escaping @Sendable (String, [WebSource]) async -> Void) async throws -> (answer: String, sources: [WebSource]) {
        // The window goes to a cloud model only if Settings allows it; otherwise the local one reads it.
        let cloud = await AppSettings.shared.cloudScreenQuestions
        let vision = await OllamaClient.supportsVision(allowCloud: cloud)
        await progress(vision ? "Looking at \(context.appName ?? "your screen")" : "Reading \(context.appName ?? "your screen")")
        let images = vision ? [context.image.flatMap { jpeg($0, maxSide: 1600) }].compactMap { $0 } : []
        let screenText = context.text.isEmpty ? "(no readable text)" : String(context.text.prefix(8000))
        let what = context.isArea ? "an area of the user's Mac screen that they picked on purpose (\"this\" means all of it)"
            : context.image == nil ? "the user's Mac screen" : "the window in front on the user's Mac"
        var user = ""
        if !context.header.isEmpty { user += context.header + "\n\n" }
        if let selection = context.selection, context.hasSelection { user += "Selected text:\n\(selection.prefix(6000))\n\n" }
        for exchange in history.suffix(3) { user += "Earlier question: \(exchange.question)\nYour answer: \(exchange.answer.prefix(600))\n\n" }
        user += "Question: \(question)\n\nText in \(context.isArea ? "the area" : "the window"):\n\(screenText)"

        // Only where there's a quiz: given always, small models put "A." in front of everything.
        let quizRule = looksLikeQuiz(context.hasSelection ? (context.selection ?? "") : context.text)
            ? "- A quiz, test or multiple-choice question: give the right answer first (the letter and the option), then one short line on why.\n" : ""
        func ask(allowSearch: Bool) async throws -> String {
            let searchRule = allowSearch ? """
            Only if the question needs outside facts you aren't sure of (recent events, scores, prices, specific figures), \
            don't guess: reply with ONLY these two lines and nothing else:
            SEARCH: <a concise search-engine query>
            SCREEN: <one sentence on what's on screen that matters for the question>

            """ : ""
            let system = """
            You can see \(what) as it is right now\(vision ? " (the image)" : ""), and its text\(context.textSource == .accessibility ? " as the app reports it" : ", read from the picture"), \
            top to bottom. Answer their question about it. Today is \(Date().formatted(date: .complete, time: .omitted)).
            - If they selected text, "this" means the selection.
            \(quizRule)- An error or code: say what's wrong and how to fix it.
            - Summarize / explain / translate / rewrite: do exactly that, nothing else.
            - Compile / list / extract: pull every matching item from the whole window, not just the first part.
            - Otherwise answer directly from what's there.
            \(searchRule)Plain text: no headings, no bold. Code goes in a ``` block. Under 130 words, unless code, rewriting, translating or a full list needs more.
            """
            // Hold the reply back until it's clear it isn't a search request.
            return try await OllamaClient.chatStream(system: system, user: user, images: images, allowCloud: cloud) { soFar in
                let head = soFar.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard head.count >= 7, !head.hasPrefix("SEARCH:") else { return }
                await partial(soFar, [])
            }
        }

        // Questions answered from what's there alone don't get the web option at all: small models
        // reached for it anyway, and a search only made those answers slower and vaguer.
        var text = try await ask(allowSearch: !isSelfContained(question))
        DebugHooks.log("Screen [\(context.label)] \(context.textSource) \(context.text.count) chars: \(question) → \(text.prefix(200))")
        // "SEARCH: [No search needed]": the model meant to answer from the window. Ask again without the option.
        if let search = line("SEARCH:", in: text), isPlaceholderQuery(search) {
            text = try await ask(allowSearch: false)
        }
        guard let search = line("SEARCH:", in: text), !isPlaceholderQuery(search) else { return (text, []) }

        let seen = line("SCREEN:", in: text) ?? ""
        let excerpt = context.hasSelection ? (context.selection ?? "") : context.text
        let screenContext = "\(seen)\n\(context.header)\nText on screen (excerpt): \(excerpt.prefix(1500))"
        return try await WebSearcher.answer(question, searchQuery: search, screenContext: screenContext,
                                            progress: progress, partial: partial)
    }

    /// A question with lettered options ("a)", "B.") or quiz words, as the suggestions check.
    static func looksLikeQuiz(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("?") && ["a)", "b)", "a.", "b.", "question", "quiz", "select", "choose"].contains(where: t.contains)
    }

    /// "Add this to my tasks", "put it in my calendar": something to do with the window, not a question.
    static func isAction(_ question: String) -> Bool {
        let q = question.lowercased()
        let verbs = ["add ", "create ", "make a", "remind me", "schedule ", "save ", "book ", "put ", "set a reminder", "note "]
        let things = ["task", "todo", "to-do", "calendar", "event", "reminder", "meeting", "note", "remind"]
        return verbs.contains(where: q.hasPrefix) && things.contains(where: q.contains)
    }

    /// Explaining, summarizing, translating, rewriting, fixing: all about what's already there.
    static func isSelfContained(_ question: String) -> Bool {
        let q = question.lowercased()
        return ["explain", "summar", "translate", "rewrite", "reword", "fix", "grammar", "spelling", "key points", "tl;dr",
                "tldr", "simplify", "what's this", "what is this", "error", "code", "reply", "respond", "shorten", "proofread",
                "compile", "bullet", "extract", "list every", "list all", "list the", "pull out", "gather", "every message", "on my screen"]
            .contains(where: q.contains)
    }

    /// Where a screen question goes, for the results and the chip.
    @MainActor static var privacyLine: String {
        let s = AppSettings.shared
        if s.aiProvider.isCloud, s.cloudScreenQuestions, CloudLLM.active != nil || s.aiProvider.cliTool != nil {
            return "Sent to \(s.aiProvider.shortName) · nothing is saved"
        }
        return "Only on this Mac · nothing is saved"
    }

    /// A SEARCH line that isn't a query: "[No search needed - all info is in the window]", "none", "N/A".
    static func isPlaceholderQuery(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.hasPrefix("[") || q.hasPrefix("<") || q.hasPrefix("(") { return true }
        let markers = ["no search", "not needed", "no need", "none", "n/a", "not required", "not necessary", "in the window", "on screen"]
        return q.count < 3 || markers.contains(where: q.contains)
    }

    private static func line(_ prefix: String, in text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.uppercased().hasPrefix(prefix) {
                let value = l.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    // MARK: - Capture

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// A smaller copy for the model: a full Retina screen is more pixels than it needs, and slower.
    static func jpeg(_ image: CGImage, maxSide: Int) -> Data? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// A small preview for the results.
    static func thumbnail(_ image: CGImage) -> NSImage? {
        guard let data = jpeg(image, maxSide: 480) else { return nil }
        return NSImage(data: data)
    }
}
