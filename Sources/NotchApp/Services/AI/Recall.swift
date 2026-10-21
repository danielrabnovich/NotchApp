import AppKit
import ApplicationServices
import Combine
import Darwin
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// Recall: an on-device memory of what was on screen, found from Search ("that error in Terminal
/// yesterday"). Off until turned on. When something changes (another app comes forward, a window's
/// title changes, or every 30 seconds while you're using the Mac), the window in front is turned
/// into text right away: its Accessibility text, title and address, or the words read off it when
/// the app exposes none; what Vision sees in it; and a small picture. Search reads only that text,
/// so a local model that can't see pictures answers from it as well as any.
///
/// Never captured: NotchApp, password managers, private browser windows, a locked or idle Mac, and
/// a screen that's being shared. It waits on low battery, in Low Power Mode and when the Mac is hot.
@MainActor
final class Recall: ObservableObject {
    static let shared = Recall()

    /// How long captures are kept.
    enum Keep: String, CaseIterable, Identifiable {
        case day, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: "1 Day"
            case .week: "1 Week"
            case .month: "1 Month"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            }
        }
    }

    /// Paused from Search ("Pause Recall"); kept across launches until resumed.
    @Published private(set) var paused = UserDefaults.standard.bool(forKey: "recallPaused")
    /// How much is kept, for Settings.
    @Published private(set) var count = 0
    @Published private(set) var bytes: Int64 = 0

    var isOn: Bool { AppSettings.shared.recall }
    var isCapturing: Bool { running }

    private var running = false
    private var cancellables = Set<AnyCancellable>()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    /// When the waiting capture was first asked for: a title that never stops changing (a spinner
    /// in a terminal's title) still gets captured after a few seconds.
    private var pendingSince: Date?
    private var lastCapture = Date.distantPast
    private var busy = false
    private var locked = false
    private var displayAsleep = false
    private var lastPrune = Date.distantPast
    private var lastBackfill = Date.distantPast
    /// The last frame kept of each window, to skip ones that look the same.
    private var lastFrames: [String: Frame] = [:]
    private var axObserver: AXObserver?
    private var observedPID: pid_t?

    /// Between captures, the floor while you're active.
    private static let floor: TimeInterval = 30

    func start() {
        AppSettings.shared.$recall.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
            .store(in: &cancellables)
        // Keeping less takes effect at once.
        AppSettings.shared.$recallKeep.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.prune() } }
            .store(in: &cancellables)
    }

    func pause() { setPaused(true) }
    func resume() { setPaused(false) }

    private func setPaused(_ on: Bool) {
        paused = on
        UserDefaults.standard.set(on, forKey: "recallPaused")
        apply()
    }

    /// Forgets the last `seconds` of captures (an hour, from Search).
    func forget(last seconds: TimeInterval) {
        let since = Date().addingTimeInterval(-seconds)
        lastFrames = [:]
        Task.detached(priority: .utility) {
            RecallStore.shared.forget(since: since)
            await self.refreshStats()
        }
    }

    func forgetAll() {
        lastFrames = [:]
        Task.detached(priority: .utility) {
            RecallStore.shared.forgetAll()
            await self.refreshStats()
        }
    }

    private func apply() {
        let on = isOn && !paused
        if on, !running { begin() } else if !on, running { end() }
        // Whatever's kept still ages out while it's off or paused.
        if isOn || FileManager.default.fileExists(atPath: RecallStore.folder.path) { prune() }
    }

    // MARK: - Triggers

    private func begin() {
        running = true
        DebugHooks.log("Recall: on")
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        func watch(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { body(note) }
            }
            observers.append((center, token))
        }
        watch(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] _ in
            self?.observeFrontmost()
            self?.schedule("app", after: 1.2)
        }
        watch(ws, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.displayAsleep = true }
        watch(ws, NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.displayAsleep = false }
        watch(ws, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.locked = true }
        watch(ws, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in self?.locked = false }
        for (name, isLocked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false),
                                 ("com.apple.screensaver.didstart", true), ("com.apple.screensaver.didstop", false)] {
            watch(dnc, Notification.Name(name)) { [weak self] _ in self?.locked = isLocked }
        }
        let timer = Timer(timeInterval: Self.floor, repeats: true) { _ in
            MainActor.assumeIsolated { Recall.shared.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observeFrontmost()
        schedule("start", after: 2)
    }

    private func end() {
        running = false
        DebugHooks.log("Recall: off")
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        pendingSince = nil
        stopObservingApp()
        lastFrames = [:]
    }

    private func tick() {
        // Housekeeping rides on the same timer: pruning hourly, vectors every ten minutes.
        if Date().timeIntervalSince(lastPrune) > 3600 { prune() }
        if Date().timeIntervalSince(lastBackfill) > 600 { backfillVectors() }
        // The floor only counts while you're at the Mac.
        guard Self.idleSeconds < Self.floor else { return }
        schedule("floor", after: 0)
    }

    /// Captures once things settle: a burst of title changes (a page loading) makes one capture.
    /// Captures are at least 10 seconds apart (2 after switching apps); one asked for sooner waits.
    private func schedule(_ reason: String, after delay: TimeInterval) {
        if pending != nil, let since = pendingSince, Date().timeIntervalSince(since) > 4 { return }
        pending?.cancel()
        let gap = reason == "app" || reason == "start" ? 2.0 : 10.0
        let wait = max(delay, gap - Date().timeIntervalSince(lastCapture))
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.pendingSince = nil
            self?.captureNow(reason)
        }
        if pending == nil { pendingSince = Date() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Watches the app in front for a new focused window or a changed title.
    private func observeFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != observedPID else { return }
        stopObservingApp()
        guard FrontmostTracker.isUserApp(app), AXIsProcessTrusted() else { return }
        let pid = app.processIdentifier
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in
            MainActor.assumeIsolated { Recall.shared.schedule("title", after: 1.5) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        for name in [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        observedPID = pid
    }

    private func stopObservingApp() {
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode) }
        axObserver = nil
        observedPID = nil
    }

    // MARK: - When not to

    /// Why a capture shouldn't happen now, or nil when it can.
    func blocker(ignoringIdle: Bool = false) -> String? {
        if !isOn { return "off" }
        if paused { return "paused" }
        if locked || displayAsleep || Self.sessionLocked { return "locked" }
        if !ignoringIdle, Self.idleSeconds > 120 { return "idle" }
        let battery = BatteryMonitor.shared
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "low power mode" }
        if battery.hasBattery, !battery.isPluggedIn, battery.level < 20 { return "low battery" }
        if [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) { return "hot" }
        if Self.screenShared { return "screen shared" }
        if !AXIsProcessTrusted() && !CGPreflightScreenCaptureAccess() { return "no permission" }
        return nil
    }

    /// Seconds since the last key press, click or pointer move.
    nonisolated static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    nonisolated private static var sessionLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true || (session["kCGSSessionOnConsoleKey"] as? Bool) == false
    }

    /// Someone is watching this screen through Screen Sharing (its daemon only runs during a session).
    /// Apps that share the screen themselves (a video call's screen share) can't be told apart cheaply.
    nonisolated static var screenShared: Bool {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return false }
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(n)) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "screensharingd" { return true }
        }
        return false
    }

    /// Bundle IDs never captured: NotchApp and the password managers clipboard history skips.
    nonisolated static let excludedApps: Set<String> = ClipboardHistory.skippedApps.union([
        Bundle.main.bundleIdentifier ?? "com.notchapp.NotchApp", "com.apple.loginwindow", "com.apple.ScreenSaver.Engine",
    ])

    // MARK: - Capturing

    /// The last frame kept of a window: what it looked like (a 256-bit difference hash) and read.
    struct Frame: Sendable {
        let hash: [UInt64]?
        let text: Int
        let title: String?
        let time: Date
    }

    private struct Target: Sendable {
        let pid: pid_t
        let bundleID: String?
        let appName: String?
    }

    private enum Outcome: Sendable {
        case saved(String, Frame)
        case same(String)
        case skipped(String)
    }

    /// Captures the window in front now (unless something rules it out). `force` (debug) ignores idle.
    func captureNow(_ reason: String, force: Bool = false) {
        if let why = blocker(ignoringIdle: force) {
            if why != "off" { DebugHooks.log("Recall: skip (\(reason)): \(why)") }
            return
        }
        guard !busy, let app = NSWorkspace.shared.frontmostApplication, FrontmostTracker.isUserApp(app) else { return }
        if let id = app.bundleIdentifier, Self.excludedApps.contains(id) {
            DebugHooks.log("Recall: skip (\(reason)): excluded app \(id)")
            return
        }
        busy = true
        lastCapture = Date()
        let target = Target(pid: app.processIdentifier, bundleID: app.bundleIdentifier, appName: app.localizedName)
        let previous = lastFrames
        Task.detached(priority: .background) {
            let outcome = await Recall.take(target, previous: previous, reason: reason)
            await MainActor.run {
                let recall = Recall.shared
                recall.busy = false
                switch outcome {
                case .saved(let key, let frame):
                    recall.lastFrames[key] = frame
                    // Windows not seen for a while don't need remembering.
                    if recall.lastFrames.count > 64 {
                        recall.lastFrames = recall.lastFrames.filter { Date().timeIntervalSince($0.value.time) < 3600 }
                    }
                    Task.detached(priority: .background) { await recall.refreshStats() }
                case .same(let key):
                    DebugHooks.log("Recall: same as before (\(reason)) \(key)")
                case .skipped(let why):
                    DebugHooks.log("Recall: skip (\(reason)): \(why)")
                }
            }
        }
    }

    private nonisolated static func take(_ target: Target, previous: [String: Frame], reason: String) async -> Outcome {
        let started = Date()
        let canSee = CGPreflightScreenCaptureAccess()
        let ax = AXReader.read(pid: target.pid, visibleOnly: true)
        guard ax != nil || canSee else { return .skipped("nothing readable") }
        if isPrivateWindow(pid: target.pid, bundleID: target.bundleID, title: ax?.title) { return .skipped("private window") }
        let key = "\(target.bundleID ?? "?")#\(ax?.windowID ?? 0)"
        let axText = ax?.text ?? ""
        let afterAX = Date()

        let image = canSee ? try? await windowImage(windowID: ax?.windowID, pid: target.pid) : nil
        let hash = image.flatMap(differenceHash)
        let frame = Frame(hash: hash, text: axText.hashValue, title: ax?.title, time: Date())
        if let last = previous[key], last.title == frame.title, isSame(last, frame) { return .same(key) }
        let afterShot = Date()

        // Accessibility text is exact and cheap; only thin text (Electron, canvases, video) is read off the picture.
        var text = axText
        var labels: [String] = []
        var ocr = false
        if let image {
            let classify = VNClassifyImageRequest()
            let read = VNRecognizeTextRequest()
            read.recognitionLevel = .accurate
            read.usesLanguageCorrection = true
            let needsOCR = axText.count < 200
            autoreleasepool {
                try? VNImageRequestHandler(cgImage: image).perform(needsOCR ? [classify, read] : [classify])
            }
            labels = (classify.results ?? []).filter { $0.confidence >= 0.3 }.prefix(10).map(\.identifier)
            if needsOCR {
                let lines = (read.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                if lines.count > text.count { text = lines; ocr = true }
            }
        }
        let afterText = Date()
        text = String(text.prefix(12_000))
        guard !text.isEmpty || !(ax?.title ?? "").isEmpty || image != nil else { return .skipped("empty") }

        var capture = RecallStore.Capture(time: started, bundleID: target.bundleID, appName: target.appName, title: ax?.title,
                                          location: ax?.location, text: text, labels: labels)
        capture.bytes = Int64(text.utf8.count)
        // Makes the folder (readable by this user only) before the picture goes in it.
        guard RecallStore.shared.open(create: true) else { return .skipped("no database") }
        if let image, let (name, size) = saveThumbnail(image, at: started) {
            capture.thumbnail = name
            capture.bytes += size
        }
        RecallStore.shared.insert(capture)
        let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
        DebugHooks.log("Recall: saved (\(reason)) \(target.appName ?? "?") “\((ax?.title ?? "").prefix(60))” \(text.count) chars\(ocr ? " (OCR)" : "") labels=\(labels.prefix(3)) | ax \(ms(started, afterAX))ms shot \(ms(afterAX, afterShot))ms text \(ms(afterShot, afterText))ms total \(ms(started, Date()))ms")
        return .saved(key, frame)
    }

    /// The same window, looking (nearly) the same and reading the same.
    private nonisolated static func isSame(_ a: Frame, _ b: Frame) -> Bool {
        guard a.text == b.text else { return false }
        guard let x = a.hash, let y = b.hash else { return a.hash == nil && b.hash == nil }
        let distance = zip(x, y).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
        return distance <= 6
    }

    /// The window by its ID (else the app's largest), never the whole display: other windows
    /// (a password manager beside it) aren't in it. Taken at up to 2560 px on the long side, which
    /// still reads small text.
    private nonisolated static func windowImage(windowID: CGWindowID?, pid: pid_t) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { windowID != nil && $0.windowID == windowID })
                ?? content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 120 })
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let longest = max(window.frame.width, window.frame.height)
        let scale = min(CGFloat(filter.pointPixelScale), 2560 / max(longest, 1))
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// A 17×16 grey copy, each pixel compared with its right-hand neighbour: 256 bits that barely
    /// move unless what's on screen does.
    nonisolated static func differenceHash(_ image: CGImage) -> [UInt64]? {
        let w = 17, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var words = [UInt64](repeating: 0, count: 4)
        for y in 0..<h {
            for x in 0..<(w - 1) where pixels[y * w + x] > pixels[y * w + x + 1] {
                let bit = y * (w - 1) + x
                words[bit / 64] |= 1 << UInt64(bit % 64)
            }
        }
        return words
    }

    /// A HEIC picture, 1280 px on the long side, in a folder per day. Its name and size.
    private nonisolated static func saveThumbnail(_ image: CGImage, at date: Date) -> (String, Int64)? {
        let day = date.formatted(.iso8601.year().month().day())
        let name = "\(day)/\(Int(date.timeIntervalSince1970 * 1000)).heic"
        let url = RecallStore.frames.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.55,
                                        kCGImageDestinationImageMaxPixelSize: 1280]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return (name, size)
    }

    // MARK: - Private windows

    /// Bundle IDs (in part) of browsers, whose toolbars are checked for a private window's badge.
    private nonisolated static let browsers = ["safari", "chrome", "chromium", "firefox", "thebrowser", "brave", "edgemac", "vivaldi",
                                               "opera", "zen", "orion", "kagi", "duckduckgo", "sigmaos", "floorp", "librewolf"]

    private nonisolated static let privateWords = ["incognito", "inprivate", "private browsing", "private window", "(private)",
                                                   "— private", "- private"]

    /// A private or incognito browser window: its title says so (Firefox, Edge, some Chromium
    /// browsers), or its toolbar does (Chrome's "Incognito" button). Page content isn't looked at,
    /// so a page that mentions privacy doesn't count.
    nonisolated static func isPrivateWindow(pid: pid_t, bundleID: String?, title: String?) -> Bool {
        let lower = (title ?? "").lowercased()
        if privateWords.contains(where: lower.contains) || lower == "private browsing" { return true }
        let id = (bundleID ?? "").lowercased()
        guard browsers.contains(where: id.contains) else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window: AXUIElement = AXReader.value(app, kAXFocusedWindowAttribute) else { return false }
        var nodes = 0
        func scan(_ element: AXUIElement, depth: Int) -> Bool {
            guard depth < 7, nodes < 400 else { return false }
            nodes += 1
            let role: String = AXReader.value(element, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" || role == "AXScrollArea" && depth > 2 { return false }
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let s: String = AXReader.value(element, attribute), s.count < 40 {
                    let l = s.lowercased()
                    if ["incognito", "inprivate", "private", "private browsing"].contains(l) { return true }
                }
            }
            let children: [AXUIElement] = AXReader.value(element, kAXChildrenAttribute) ?? []
            return children.contains { scan($0, depth: depth + 1) }
        }
        return scan(window, depth: 0)
    }

    // MARK: - Housekeeping

    private func prune() {
        lastPrune = Date()
        let keep = AppSettings.shared.recallKeep.seconds
        Task.detached(priority: .background) {
            RecallStore.shared.prune(keep: keep)
            await self.refreshStats()
        }
    }

    /// Gives captures MobileCLIP vectors in batches, from their pictures, when the model is
    /// installed: loading it for every capture would keep its 100+ MB in memory all day.
    func backfillVectors(limit: Int = 60) {
        lastBackfill = Date()
        guard VisualSearch.isUsable else { return }
        Task.detached(priority: .background) {
            let todo = RecallStore.shared.needingVectors(limit: limit)
            guard !todo.isEmpty, let clip = VisualSearch.model else { return }
            for (id, url) in todo {
                autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                                      kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary),
                          let vector = try? clip.embed(image: image) else { return }
                    RecallStore.shared.setVector(id, vector)
                }
            }
            DebugHooks.log("Recall: \(todo.count) vectors added")
        }
    }

    nonisolated func refreshStats() async {
        let count = RecallStore.shared.count
        let bytes = RecallStore.shared.usedBytes()
        await MainActor.run {
            if self.count != count { self.count = count }
            if self.bytes != bytes { self.bytes = bytes }
        }
    }
}
