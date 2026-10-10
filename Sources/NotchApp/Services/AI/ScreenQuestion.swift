import AppKit
import ScreenCaptureKit
import Vision

/// Answers a question about what's on screen ("what's the right answer to this question",
/// "explain this error"): a silent capture of the display behind the notch (in memory only, never
/// saved), the text on it read with Vision, then the local model looks at both. When it needs
/// facts it doesn't have, it writes a web query and the answer comes from the web instead. Only
/// that query leaves the Mac; the picture never does.
enum ScreenQuestion {
    struct Capture: @unchecked Sendable {
        let image: CGImage
        let text: String
    }

    struct ScreenError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func answer(_ question: String, capture: Capture,
                       progress: @escaping @Sendable (String) async -> Void,
                       partial: @escaping @Sendable (String, [WebSource]) async -> Void) async throws -> (answer: String, sources: [WebSource]) {
        let vision = await OllamaClient.supportsVision()
        await progress(vision ? "Looking at your screen" : "Reading your screen")
        let images = vision ? [jpeg(capture.image, maxSide: 1600)].compactMap { $0 } : []
        let screenText = capture.text.isEmpty ? "(no readable text)" : String(capture.text.prefix(6000))
        let system = """
        You can see the user's Mac screen as it is right now\(vision ? " (the image)" : ""), and the text read from it, \
        top to bottom. Answer their question about what's on screen. Today is \(Date().formatted(date: .complete, time: .omitted)).
        - A quiz, test or multiple-choice question: give the right answer first (the letter and the option), then one short line on why.
        - An error or code: say what's wrong and how to fix it.
        - Otherwise answer directly from what's on screen.
        If answering needs facts that aren't on screen and that you aren't sure of (recent events, scores, prices, \
        specific figures), don't guess: reply with ONLY these two lines and nothing else:
        SEARCH: <a concise search-engine query>
        SCREEN: <one sentence on what's on screen that matters for the question>
        Plain text only: no markdown, no headings, no bold. Under 110 words.
        """
        let user = "Question: \(question)\n\nText on screen:\n\(screenText)"

        // Hold the reply back until it's clear it isn't a search request.
        let text = try await OllamaClient.chatStream(system: system, user: user, images: images) { soFar in
            let head = soFar.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard head.count >= 7, !head.hasPrefix("SEARCH:") else { return }
            await partial(soFar, [])
        }
        DebugHooks.log("Screen: \(question) → \(text.prefix(200))")
        guard let search = line("SEARCH:", in: text) else { return (text, []) }

        let seen = line("SCREEN:", in: text) ?? ""
        let context = "\(seen)\nText on screen (excerpt): \(capture.text.prefix(1500))"
        return try await WebSearcher.answer(question, searchQuery: search, screenContext: context,
                                            progress: progress, partial: partial)
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

    /// The display the pointer is on, without NotchApp's own windows, then the text on it.
    static func capture() async throws -> Capture {
        // Debug: answer about a saved image instead of the live screen.
        if UserDefaults.standard.bool(forKey: "debugHooks"), let path = UserDefaults.standard.string(forKey: "debugScreenImage"),
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return Capture(image: image, text: await recognizeText(in: image))
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenError(message: "To see your screen, NotchApp needs Screen Recording (a different list from Accessibility). Turn NotchApp on there, then reopen NotchApp when macOS asks.")
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw ScreenError(message: "Couldn't find a display to look at.")
        }
        let mine = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(Float(display.width) * filter.pointPixelScale)
        config.height = Int(Float(display.height) * filter.pointPixelScale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Capture(image: image, text: await recognizeText(in: image))
    }

    private static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: image).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
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
