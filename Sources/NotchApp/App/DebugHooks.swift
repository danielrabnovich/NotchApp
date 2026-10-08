import AppKit

/// Developer hooks for previewing states without touching the mouse.
/// Enable with: defaults write com.notchapp.NotchApp debugHooks -bool YES
/// Then: swift scripts/debug.swift open home | close | volume 0.5 | snapshot /tmp/x.png …
@MainActor
enum DebugHooks {
    static let name = Notification.Name("com.notchapp.debug")
    /// While pinned, the mouse tracker won't close the notch.
    static var pinned = false

    /// Appends a line to /tmp/notchapp-debug.log when debug hooks are enabled.
    nonisolated static func log(_ line: String) {
        guard UserDefaults.standard.bool(forKey: "debugHooks") else { return }
        let url = URL(fileURLWithPath: "/tmp/notchapp-debug.log")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }

    static func install(controllers: @escaping () -> [NotchWindowController]) {
        guard UserDefaults.standard.bool(forKey: "debugHooks") else { return }
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command, controllers()) }
        }
    }

    private static func run(_ command: String, _ controllers: [NotchWindowController]) {
        let parts = command.split(separator: " ").map(String.init)
        guard let verb = parts.first, let c = controllers.first else { return }
        switch verb {
        case "pin": pinned = parts[safe: 1] != "0"
        case "open": c.viewModel.open(tab: parts.count > 1 ? NotchTab(rawValue: parts[1]) : nil, takeKeyboard: false)
        case "openkey": c.viewModel.open(tab: parts.count > 1 ? NotchTab(rawValue: parts[1]) : nil)
        case "addtask": TaskStore.shared.add(title: parts.dropFirst().joined(separator: " "))
        case "done": if let t = TaskStore.shared.open.first { TaskStore.shared.setDone(t.id, true) }
        case "page": c.viewModel.pageOffset = CGFloat(Double(parts[safe: 1] ?? "0") ?? 0)
        case "drag":
            c.viewModel.dragPreview = DragPreview(taskTitle: "Reply to Sarah about the Q3 budget", hasFiles: false, icon: "envelope.fill")
            c.viewModel.isDragActive = parts[safe: 1] != "0"
        case "duesoon":
            TaskStore.shared.add(TaskItem(title: "Send updated deck to Sarah", due: Date().addingTimeInterval(95 * 60)))
        case "brief": BriefingService.shared.maybeShowBrief(force: true)
        case "state":
            log("STATE appActive=\(NSApp.isActive) panelKey=\(c.panelContentView?.window?.isKeyWindow ?? false) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
        case "frames":
            if parts[safe: 1] == "stop" { FrameProbe.shared.stop() } else { FrameProbe.shared.start(view: c.panelContentView) }
        case "swipe": c.simulateSwipe(left: parts[safe: 1] != "right")
        case "webshelf":
            if let job = AssistantStore.shared.current, let first = job.sources.first {
                ShelfStore.shared.addLink(first.url, title: first.title)
                ShelfStore.shared.addAnswer(question: job.query, answer: job.answer ?? "", sources: job.sources)
            }
        case "clear": AssistantStore.shared.clear()
        case "ask": AssistantStore.shared.run(parts.dropFirst().joined(separator: " "))
        case "plan": AssistantStore.shared.run(parts.dropFirst().joined(separator: " "), route: .actions)
        case "cmd": CommandCenter.shared.run(Array(CommandParser.parse(parts.dropFirst().joined(separator: " ")).prefix(1)))
        case "applyplan": if let plan = AssistantStore.shared.current?.plan { CommandCenter.shared.run(plan.commands); AssistantStore.shared.clear() }
        case "fakeplay": MediaController.shared.debugSetPlaying(parts[safe: 1] != "0")
        case "expand": SystemMonitor.shared.debugExpand = "\(parts[safe: 1] ?? "")#\(Date().timeIntervalSince1970)"
        case "timer":
            switch parts[safe: 1] {
            case "start": TimerStore.shared.start()
            case "pause": TimerStore.shared.pause()
            case "skip": TimerStore.shared.skip()
            default: TimerStore.shared.reset()
            }
        case "pane": // pane notes|tasks|downloads|shelf
            let p = parts[safe: 1] ?? ""
            UserDefaults.standard.set(p, forKey: ["notes", "tasks"].contains(p) ? "tasks.pane" : "shelf.pane")
        case "peek":
            ActivityCenter.shared.show(parts[safe: 1] == "download" ? .download(name: "Report-final.pdf")
                                                                    : .timer(message: "Short break · 5 min"), for: 5)
        case "settings": SettingsWindowController.shared.show(pane: SettingsPane(rawValue: parts.dropFirst().joined(separator: " ")))
        case "pull": AssistantStore.shared.pullModel(parts[safe: 1])
        case "cancelpull": AssistantStore.shared.cancelPull()
        case "suggest": SearchSuggestions.shared.update(parts.dropFirst().joined(separator: " "))
        case "taildrop": TaildropService.shared.offer([URL(fileURLWithPath: parts.dropFirst().joined(separator: " "))])
        case "mirror": c.viewModel.mirror = parts[safe: 1] != "0"
        case "updates":
            if parts[safe: 1] == "list" { UpdateChecker.shared.listOpen = true } else { UpdateChecker.shared.check() }
        case "awake":
            if let m = Int(parts[safe: 1] ?? "") { KeepAwake.shared.start(.minutes(m)) } else { KeepAwake.shared.stop() }
        case "close": c.viewModel.close()
        case "hover": c.viewModel.isHovering = parts.count > 1 ? parts[1] == "1" : true
        case "volume": ActivityCenter.shared.show(.volume(level: Float(parts[safe: 1] ?? "0.6") ?? 0.6, muted: false), for: 5)
        case "brightness": ActivityCenter.shared.show(.brightness(level: Float(parts[safe: 1] ?? "0.4") ?? 0.4), for: 5)
        case "charging": ActivityCenter.shared.show(.charging(level: BatteryMonitor.shared.level), for: 5)
        case "meeting": ActivityCenter.shared.show(.meeting(title: "Design review", minutes: 5, color: .systemOrange), for: 6)
        case "screenshot": ActivityCenter.shared.show(.screenshot(count: 1), for: 5)
        case "snapshot":
            let path = parts[safe: 1] ?? "/tmp/notch.png"
            c.snapshot(to: URL(fileURLWithPath: path))
        default: break
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension NotchWindowController {
    /// Renders this notch window's content to a PNG (own windows need no screen-recording permission).
    func snapshot(to url: URL) {
        guard let view = panelContentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Composite on a grey backdrop so the black notch is visible.
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor(white: 0.55, alpha: 1).setFill()
        view.bounds.fill()
        rep.draw(in: view.bounds)
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}

/// Debug: records time between display-link frames to find dropped frames.
@MainActor
final class FrameProbe: NSObject {
    static let shared = FrameProbe()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []

    func start(view: NSView?) {
        guard let view else { return }
        gaps = []
        last = 0
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    nonisolated(unsafe) static var marks: [(String, CFTimeInterval)] = []
    nonisolated static func mark(_ name: String) { marks.append((name, CACurrentMediaTime())) }
    private var slow: [String] = []

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 {
            let gap = (link.timestamp - last) * 1000
            gaps.append(gap)
            if gap > 20, let m = Self.marks.last(where: { $0.1 <= link.timestamp }) {
                slow.append(String(format: "%.0fms@%@+%.0fms", gap, m.0, (link.timestamp - m.1) * 1000))
            }
        }
        last = link.timestamp
    }

    func stop() {
        link?.invalidate()
        link = nil
        if !slow.isEmpty { DebugHooks.log("SLOW " + slow.joined(separator: " ")) }
        slow = []
        guard !gaps.isEmpty else { return }
        let sorted = gaps.sorted()
        let budget = sorted[sorted.count / 2] // the display's normal frame interval
        let dropped = gaps.filter { $0 > budget * 1.5 }
        DebugHooks.log(String(format: "FRAMES n=%d median=%.1fms p95=%.1fms max=%.1fms dropped=%d (%.0f%%) worst=%@",
                              gaps.count, budget, sorted[Int(Double(sorted.count) * 0.95)], sorted.last!, dropped.count,
                              100 * Double(dropped.count) / Double(gaps.count),
                              dropped.sorted(by: >).prefix(6).map { String(format: "%.0f", $0) }.joined(separator: ",")))
    }
}
