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
        case "open": c.viewModel.open(tab: parts.count > 1 ? NotchTab(rawValue: parts[1]) : nil)
        case "addtask": TaskStore.shared.add(title: parts.dropFirst().joined(separator: " "))
        case "done": if let t = TaskStore.shared.open.first { TaskStore.shared.setDone(t.id, true) }
        case "page": c.viewModel.pageOffset = CGFloat(Double(parts[safe: 1] ?? "0") ?? 0)
        case "drag":
            c.viewModel.dragPreview = DragPreview(taskTitle: "Reply to Sarah about the Q3 budget", hasFiles: false, icon: "envelope.fill")
            c.viewModel.isDragActive = parts[safe: 1] != "0"
        case "duesoon":
            TaskStore.shared.add(TaskItem(title: "Send updated deck to Sarah", due: Date().addingTimeInterval(95 * 60)))
        case "brief": BriefingService.shared.maybeShowBrief(force: true)
        case "clear": AssistantStore.shared.clear()
        case "ask": AssistantStore.shared.run(parts.dropFirst().joined(separator: " "))
        case "fakeplay": MediaController.shared.debugSetPlaying(parts[safe: 1] != "0")
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
