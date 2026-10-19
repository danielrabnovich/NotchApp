import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// What's in front of you, for a question about it: the frontmost window (not the whole display),
/// its app, title and web address, whatever text is selected, and the window's text — read through
/// Accessibility where the app exposes it (exact, includes text scrolled out of view), else read off
/// the picture with Vision. Held in memory only; never saved.
struct ScreenContext: @unchecked Sendable {
    enum TextSource { case accessibility, ocr }

    let image: CGImage?
    /// The app it came from, to paste an AI Command's result back into.
    var pid: pid_t? = nil
    let appName: String?
    let bundleID: String?
    let windowTitle: String?
    /// The page's address in a browser, or the open document's path.
    let location: String?
    let selection: String?
    let text: String
    let textSource: TextSource
    let capturedAt = Date()

    /// "Safari — Pricing · stripe.com", for the chip and the model.
    var label: String {
        let host = location.flatMap { URL(string: $0)?.host() }
        let title = [windowTitle, host].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        return [appName, title.isEmpty ? nil : title].compactMap { $0 }.joined(separator: " — ")
    }

    var hasSelection: Bool { !(selection ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The lines the model reads about where this came from.
    var header: String {
        var lines: [String] = []
        if let appName { lines.append("App: \(appName)") }
        if let windowTitle, !windowTitle.isEmpty { lines.append("Window: \(windowTitle)") }
        if let location { lines.append("Address: \(location)") }
        return lines.joined(separator: "\n")
    }
}

extension ScreenContext {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Captures the frontmost app's focused window. Falls back to the display under the pointer
    /// when the window can't be found (a full-screen game, the desktop).
    static func capture() async throws -> ScreenContext {
        // Debug: a saved image instead of the live screen.
        if UserDefaults.standard.bool(forKey: "debugHooks"), let path = UserDefaults.standard.string(forKey: "debugScreenImage"),
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return ScreenContext(image: image, appName: nil, bundleID: nil, windowTitle: nil, location: nil, selection: nil,
                                 text: await recognizeText(in: image), textSource: .ocr)
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw Failure(message: "To see your screen, NotchApp needs Screen Recording (a different list from Accessibility). Turn NotchApp on there, then reopen NotchApp when macOS asks.")
        }
        let app = await MainActor.run { frontmostOtherApp() }
        // Accessibility first (fast, and it names the window the picture should be of).
        let ax = await Task.detached(priority: .userInitiated) { app.map { AXReader.read(pid: $0.processIdentifier) } ?? nil }.value
        let image = try await captureImage(windowID: ax?.windowID, pid: app?.processIdentifier)

        // Enough real text from Accessibility? Otherwise (pictures, canvases, PDFs, some apps
        // expose nothing) read the picture.
        var text = ax?.text ?? ""
        var source = ScreenContext.TextSource.accessibility
        if text.count < 200, let image {
            let read = await recognizeText(in: image)
            if read.count > text.count {
                text = read
                source = .ocr
            }
        }
        return ScreenContext(image: image, pid: app?.processIdentifier, appName: app?.localizedName, bundleID: app?.bundleIdentifier,
                             windowTitle: ax?.title, location: ax?.location, selection: ax?.selection,
                             text: text, textSource: source)
    }

    /// The app in front, or (when NotchApp itself is, after using Settings) the one you were in before.
    @MainActor private static func frontmostOtherApp() -> NSRunningApplication? {
        FrontmostTracker.shared.userApp
    }

    /// The window by its ID (or the app's largest on-screen window), else the display under the pointer.
    private static func captureImage(windowID: CGWindowID?, pid: pid_t?) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let window = content.windows.first { windowID != nil && $0.windowID == windowID }
            ?? content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 120 }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        let config = SCStreamConfiguration()
        config.showsCursor = false
        let filter: SCContentFilter
        if let window {
            filter = SCContentFilter(desktopIndependentWindow: window)
            config.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
            config.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
        } else {
            let displayID: CGDirectDisplayID? = await MainActor.run {
                let mouse = NSEvent.mouseLocation
                let screen: NSScreen? = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
                return screen?.displayID
            }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                throw Failure(message: "Couldn't find a display to look at.")
            }
            let mine = content.applications.filter { $0.processID == getpid() }
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            config.width = Int(Float(display.width) * filter.pointPixelScale)
            config.height = Int(Float(display.height) * filter.pointPixelScale)
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let text = autoreleasepool {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    try? VNImageRequestHandler(cgImage: image).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                }
                continuation.resume(returning: text)
            }
        }
    }
}

/// Reads the focused window of an app through Accessibility: title, address, selection and text.
/// Time-boxed and size-capped, so a huge page or a slow app never holds things up.
enum AXReader {
    struct Result {
        var windowID: CGWindowID?
        var title: String?
        var location: String?
        var selection: String?
        var text = ""
    }

    private static let charLimit = 16_000
    private static let nodeLimit = 6_000
    private static let timeLimit: TimeInterval = 0.4

    static func read(pid: pid_t) -> Result? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // A hung app shouldn't hang us.
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window: AXUIElement = value(app, kAXFocusedWindowAttribute) ?? value(app, kAXMainWindowAttribute) else { return nil }
        var result = Result()
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(window, &id) == .success { result.windowID = id }
        result.title = value(window, kAXTitleAttribute)
        if let document: String = value(window, kAXDocumentAttribute) {
            result.location = URL(string: document).map { $0.isFileURL ? $0.path : $0.absoluteString } ?? document
        }
        if let focused: AXUIElement = value(app, kAXFocusedUIElementAttribute),
           let selected: String = value(focused, kAXSelectedTextAttribute),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.selection = String(selected.prefix(8_000))
        }

        var lines: [String] = []
        var chars = 0, nodes = 0
        let deadline = Date().addingTimeInterval(timeLimit)
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 60, nodes < nodeLimit, chars < charLimit, Date() < deadline else { return }
            nodes += 1
            let role: String = value(element, kAXRoleAttribute) ?? ""
            // A browser's page: its address.
            if role == "AXWebArea", result.location == nil, let url: URL = value(element, "AXURL") {
                result.location = url.absoluteString
            }
            if let line = text(of: element, role: role) {
                lines.append(line)
                chars += line.count
            }
            // Controls' insides are chrome, not content.
            guard !["AXButton", "AXPopUpButton", "AXMenuButton", "AXScrollBar", "AXSlider", "AXImage"].contains(role),
                  let children: [AXUIElement] = value(element, kAXChildrenAttribute) else { return }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)

        // Neighbouring nodes often repeat each other (a link and its text); drop exact repeats.
        var seen = Set<String>()
        result.text = String(lines.filter { seen.insert($0).inserted }.joined(separator: "\n").prefix(charLimit))
        return result
    }

    private static func text(of element: AXUIElement, role: String) -> String? {
        let raw: String?
        switch role {
        case "AXStaticText", "AXTextArea", "AXTextField", "AXComboBox", "AXCell":
            raw = value(element, kAXValueAttribute)
        case "AXHeading", "AXLink":
            // Their text usually lives in a static-text child, read on the way down.
            raw = nil
        default:
            raw = nil
        }
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success, let ref else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return (ref as! AXUIElement) as? T
        }
        return ref as? T
    }
}

/// The window number behind an Accessibility window (private, but long-stable and widely used).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Remembers the last app other than NotchApp that was in front.
@MainActor
final class FrontmostTracker {
    static let shared = FrontmostTracker()
    private(set) var lastOther: NSRunningApplication?
    private var observer: NSObjectProtocol?

    /// The app the user is working in: the one in front, or the last one when NotchApp itself (or
    /// a system dialog, the Dock, Spotlight) is.
    var userApp: NSRunningApplication? {
        if let app = NSWorkspace.shared.frontmostApplication, Self.isUserApp(app) { return app }
        return lastOther.flatMap { $0.isTerminated ? nil : $0 }
    }

    /// A regular app, not NotchApp: permission prompts, the Dock and other agents don't count.
    static func isUserApp(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != getpid() && app.activationPolicy == .regular
    }

    func start() {
        lastOther = NSWorkspace.shared.frontmostApplication.flatMap { Self.isUserApp($0) ? $0 : nil }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, FrontmostTracker.isUserApp(app) { FrontmostTracker.shared.lastOther = app }
            }
        }
    }
}
