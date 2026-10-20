import AppKit
import SwiftUI
import Security

/// Developer hooks for previewing states without touching the mouse.
/// Enable with: defaults write com.notchapp.NotchApp debugHooks -bool YES
/// Then: swift scripts/debug.swift open home | close | volume 0.5 | snapshot /tmp/x.png …
///
/// Commands arrive as distributed notifications, which any app on the Mac can post (sandboxed ones
/// too), so each must start with a token NotchApp writes at launch to a file only this user can
/// read (`tokenFile`); scripts/debug.swift adds it. The log is private to this user as well.
@MainActor
enum DebugHooks {
    static let name = Notification.Name("com.notchapp.debug")
    /// While pinned, the mouse tracker won't close the notch.
    static var pinned = false

    /// ~/Library/Logs/NotchApp/debug.log: searches, answers and screen questions go in it, so it's
    /// readable only by this user (not /tmp, which every account can read).
    nonisolated static let logFile: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NotchApp/debug.log")

    nonisolated static let tokenFile: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchApp/debug-token")

    /// Appends a line to the debug log when debug hooks are enabled.
    nonisolated static func log(_ line: String) {
        guard UserDefaults.standard.bool(forKey: "debugHooks") else { return }
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: logFile) { h.seekToEndOfFile(); h.write(data); try? h.close(); return }
        let fm = FileManager.default
        try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: logFile.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private static var token = ""

    static func install(controllers: @escaping () -> [NotchWindowController]) {
        guard UserDefaults.standard.bool(forKey: "debugHooks") else {
            try? FileManager.default.removeItem(at: tokenFile)
            return
        }
        // A fresh secret each launch, in a file only this user can read.
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        try? fm.removeItem(at: tokenFile)
        guard fm.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else { return }
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let raw = note.object as? String ?? ""
            MainActor.assumeIsolated {
                // "<token> <command>": anything without the token is ignored.
                guard let space = raw.firstIndex(of: " "), !token.isEmpty,
                      constantTimeEqual(String(raw[..<space]), token) else { return }
                run(String(raw[raw.index(after: space)...]), controllers())
            }
        }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func run(_ command: String, _ controllers: [NotchWindowController]) {
        let parts = command.split(separator: " ").map(String.init)
        guard let verb = parts.first, let c = controllers.first else { return }
        switch verb {
        case "pin": pinned = parts[safe: 1] != "0"
        case "open": c.viewModel.open(tab: parts.count > 1 ? NotchTab(rawValue: parts[1]) : nil, takeKeyboard: false)
        case "openkey": c.viewModel.open(tab: parts.count > 1 ? NotchTab(rawValue: parts[1]) : nil, reason: .keyboard)
        case "addtask": TaskStore.shared.add(title: parts.dropFirst().joined(separator: " "))
        case "done": if let t = TaskStore.shared.open.first { TaskStore.shared.setDone(t.id, true) }
        case "page": // page <offset>: holds the pages there, as a finger would; "page release" lets go
            if parts[safe: 1] == "release" { c.viewModel.slide(to: c.viewModel.tab, velocity: 0) } else {
                c.viewModel.ensureNeighbors()
                c.viewModel.pager.drag(to: CGFloat(Double(parts[safe: 1] ?? "0") ?? 0))
            }
        case "pager": log(c.viewModel.pager.debugState)
        case "drag":
            // drag files <path…>: the drop bins as for those files (one-drop conversions included)
            c.viewModel.dragPreview = DragPreview(taskTitle: "Reply to Sarah about the Q3 budget", hasFiles: parts[safe: 1] == "files", icon: "envelope.fill",
                                                  files: parts.dropFirst(2).map { URL(fileURLWithPath: $0) })
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
        case "fakecall": MeetingAssistant.shared.debugMeeting()
        case "dictate": RambleStore.shared.toggleDictation()
        case "ramblelog": log("RAMBLE dictating=\(RambleStore.shared.dictating) hearing=\(RambleStore.shared.hearing) text=\(RambleStore.shared.text.suffix(200))")
        case "soundtest": SoundAlerts.shared.debugAnyOutput = parts[safe: 1] != "0"; SoundAlerts.shared.reconcile()
        case "soundlog": SoundAlerts.shared.reconcile(); log("SOUNDS on=\(AppSettings.shared.soundAlerts) output=\(AudioOutputManager.shared.current?.name ?? "-") transport=\(AudioOutputManager.shared.current?.transport ?? 0)")
        case "planlog": // the proposed commands under review
            log("PLAN " + (AssistantStore.shared.current?.plan?.commands.map { "[\($0.title) | \($0.subtitle ?? "")]" }.joined(separator: " ") ?? "none"))
        case "meetingsclear": // removes kept calls with this exact title
            let title = parts.dropFirst().joined(separator: " ")
            MeetingAssistant.shared.meetings.filter { $0.title == title }.forEach { MeetingAssistant.shared.delete($0.id) }
        case "followup": AssistantStore.shared.runFollowUp()
        case "askstate": // where the last question is up to, and its answer
            let job = AssistantStore.shared.current
            log("ASKSTATE status=\(AssistantStore.shared.status) route=\(String(describing: job?.route)) state=\(String(describing: job?.state)) answer=\((job?.answer ?? "").prefix(300))")
        case "plan": AssistantStore.shared.run(parts.dropFirst().joined(separator: " "), route: .actions)
        case "doinapp": AssistantStore.shared.run(parts.dropFirst().joined(separator: " "), route: .app)
        case "cmd": CommandCenter.shared.run(Array(CommandParser.parse(parts.dropFirst().joined(separator: " ")).prefix(1)))
        case "applyplan": if let plan = AssistantStore.shared.current?.plan { CommandCenter.shared.run(plan.commands); AssistantStore.shared.clear() }
        case "fakeplay": MediaController.shared.debugSetPlaying(parts[safe: 1] != "0")
        case "expand": SystemMonitor.shared.debugExpand = "\(parts[safe: 1] ?? "")#\(Date().timeIntervalSince1970)"
        case "timer":
            switch parts[safe: 1] {
            case "start": TimerStore.shared.start()
            case "pause": TimerStore.shared.pause()
            case "skip": TimerStore.shared.skip()
            case "mode": // timer mode timer|pomodoro|stopwatch
                if let mode = TimerStore.Mode(rawValue: parts[safe: 2] ?? "") { TimerStore.shared.mode = mode }
            default: TimerStore.shared.reset()
            }
        case "pane": // pane notes|tasks|downloads|shelf
            let p = parts[safe: 1] ?? ""
            let key = ["notes", "tasks"].contains(p) ? "tasks.pane" : ["network", "vpn", "cleaner", "devices"].contains(p) ? "tools.pane" : "shelf.pane"
            UserDefaults.standard.set(p, forKey: key)
        case "sim": DebugSimulator.run(parts[safe: 1] ?? "", Array(parts.dropFirst(2)))
        case "appearance": // appearance light|dark|system: this app only, the Mac stays as it is
            NSApp.appearance = ["light": NSAppearance(named: .aqua), "dark": NSAppearance(named: .darkAqua)][parts[safe: 1] ?? ""] ?? nil
        case "spane": // spane <pane raw value…>: opens Settings on a pane at 900×1100
            SettingsWindowController.shared.show(pane: SettingsPane(rawValue: parts.dropFirst().joined(separator: " ")))
            SettingsWindowController.shared.debugResize(width: 900, height: 1100)
        case "sresize": // sresize <w> <h>: resizes Settings (taller than the screen, to snapshot a long pane)
            SettingsWindowController.shared.debugResize(width: CGFloat(Double(parts[safe: 1] ?? "") ?? 900), height: CGFloat(Double(parts[safe: 2] ?? "") ?? 1100))
        case "sshot": SettingsWindowController.shared.debugSnapshot(to: URL(fileURLWithPath: parts[safe: 1] ?? "/tmp/settings.png"))
        case "smove", "sclick", "srclick": // x y in points, top-left of the content
            let x = CGFloat(Double(parts[safe: 1] ?? "") ?? 0), y = CGFloat(Double(parts[safe: 2] ?? "") ?? 0)
            let w = SettingsWindowController.shared
            switch verb {
            case "smove": w.debugMouse(.mouseMoved, x: x, y: y)
            case "srclick": w.debugMouse(.rightMouseDown, x: x, y: y); w.debugMouse(.rightMouseUp, x: x, y: y)
            default: w.debugMouse(.mouseMoved, x: x, y: y); w.debugMouse(.leftMouseDown, x: x, y: y); w.debugMouse(.leftMouseUp, x: x, y: y)
            }
        case "sdrag": // sdrag x1 y1 x2 y2: press, drag in steps, release (points, top-left of the content)
            let v = parts.dropFirst().compactMap { Double($0) }.map { CGFloat($0) }
            guard v.count == 4 else { break }
            let w = SettingsWindowController.shared
            w.debugMouse(.mouseMoved, x: v[0], y: v[1])
            w.debugMouse(.leftMouseDown, x: v[0], y: v[1])
            for i in 1...12 {
                let t = CGFloat(i) / 12
                w.debugMouse(.leftMouseDragged, x: v[0] + (v[2] - v[0]) * t, y: v[1] + (v[3] - v[1]) * t)
            }
            w.debugMouse(.leftMouseUp, x: v[2], y: v[3])
        case "clipsuggest": // clipsuggest <kind> <text…>: logs what the clipboard would offer (runs nothing)
            let kind = ClipboardHistory.Clip.Kind(rawValue: parts[safe: 1] ?? "") ?? .text
            let text = parts.dropFirst(2).joined(separator: " ").replacingOccurrences(of: "\\n", with: "\n")
            let clip = ClipboardHistory.Clip(id: UUID(), kind: kind, text: text, date: Date())
            log("SUGGEST [\(text.replacingOccurrences(of: "\n", with: "⏎"))] → " + ClipActions.suggestions(for: clip).map(\.title).joined(separator: " | "))
        case "nmove", "nclick", "nrclick": // x y in points, top-left of the notch panel's content
            guard let window = c.panelContentView?.window, let view = window.contentView else { break }
            // The panel only takes the mouse while the real pointer is over it; pinned, let it.
            window.ignoresMouseEvents = false
            let x = CGFloat(Double(parts[safe: 1] ?? "") ?? 0), y = CGFloat(Double(parts[safe: 2] ?? "") ?? 0)
            let point = view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
            let types: [NSEvent.EventType] = verb == "nmove" ? [.mouseMoved]
                : verb == "nrclick" ? [.mouseMoved, .rightMouseDown, .rightMouseUp] : [.mouseMoved, .leftMouseDown, .leftMouseUp]
            for type in types {
                if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseUp ? 0 : 1) { NSApp.postEvent(e, atStart: false) }
            }
        case "nbounds": log("NBOUNDS \(c.panelContentView?.bounds ?? .zero) flipped=\(c.panelContentView?.isFlipped ?? false) ignores=\(c.panelContentView?.window?.ignoresMouseEvents ?? true)")
        case "cliprun": // cliprun <index> <action id>: runs a clip's suggestion like the card does
            let clips = ClipboardHistory.shared.clips
            guard let i = Int(parts[safe: 1] ?? ""), clips.indices.contains(i) else { break }
            let all = ClipActions.suggestions(for: clips[i])
            let pick = all.first { $0.id == parts[safe: 2] }
            log("CLIPRUN \(clips[i].title.prefix(30)) offers [\(all.map(\.id).joined(separator: ","))] → \(pick?.run() ?? "no such action")")
        case "notestrim": // notestrim <text…>: removes that line from the end of Notes (undoes a test)
            let line = parts.dropFirst().joined(separator: " ")
            let store = ScratchpadStore.shared
            if store.text.hasSuffix("\n" + line) { store.text.removeLast(line.count + 1) }
            else if store.text == line { store.text = "" }
        case "notes": log("NOTES-TAIL \(ScratchpadStore.shared.text.suffix(80))")
        case "tiles": log("TILES \(ControlTiles.shared.tiles.map(\.rawValue).joined(separator: ","))")
        case "skey": // skey <keycode> <chars> [cmd,opt,ctrl,shift]
            var flags: NSEvent.ModifierFlags = []
            for m in (parts[safe: 3] ?? "").split(separator: ",") {
                switch m { case "cmd": flags.insert(.command); case "opt": flags.insert(.option)
                case "ctrl": flags.insert(.control); case "shift": flags.insert(.shift); default: break }
            }
            SettingsWindowController.shared.debugKey(code: UInt16(parts[safe: 1] ?? "") ?? 0, characters: parts[safe: 2] ?? "", modifiers: flags)
        case "keywin": log("KEYWIN \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none") open=\(c.viewModel.isOpen)")
        case "overrides": log("OVERRIDES \(AppSettings.shared.hotKeyOverrides.mapValues(\.display))")
        case "settingsshot": // settingsshot <path> <pane title…>
            SettingsWindowController.shared.show(pane: SettingsPane(rawValue: parts.dropFirst(2).joined(separator: " ")))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                SettingsWindowController.shared.snapshot(to: URL(fileURLWithPath: parts[safe: 1] ?? "/tmp/settings.png"))
            }
        case "batteryglyphs": // batteryglyphs <path>: every battery state, rendered side by side
            let states: [(Int, Bool, Bool, Bool)] = [(100, false, false, false), (82, false, false, false), (64, true, true, false),
                                                     (100, false, true, false), (45, false, false, true), (18, false, false, false),
                                                     (7, false, false, false), (7, true, true, false)]
            let view = HStack(spacing: 14) {
                ForEach(states.indices, id: \.self) { i in
                    let s = states[i]
                    BatteryGlyph(level: s.0, charging: s.1, pluggedIn: s.2, lowPower: s.3)
                }
            }
            .padding(14)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 4
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: parts[safe: 1] ?? "/tmp/battery.png"))
            }
        case "askscreen": // what the "Ask about this" shortcut does
            AssistantStore.shared.clear()
            AssistantStore.shared.captureContext()
            c.viewModel.open(tab: .ask, reason: .keyboard)
        case "ctx": // what the captured window holds
            switch AssistantStore.shared.context {
            case let .ready(x, _)?:
                log("CTX \(x.label) | src=\(x.textSource) chars=\(x.text.count) sel=\(x.selection?.count ?? 0) loc=\(x.location ?? "-") img=\(x.image.map { "\($0.width)x\($0.height)" } ?? "none")")
                log("CTX-TEXT " + x.text.prefix(300).replacingOccurrences(of: "\n", with: " ⏎ "))
            case .capturing?: log("CTX capturing")
            case .failed(let m)?: log("CTX failed: \(m)")
            case nil: log("CTX none")
            }
        case "cloudtest": // cloudtest <provider> <key> [model]: one request straight through CloudLLM (no Keychain)
            guard let provider = AIProvider(rawValue: parts[safe: 1] ?? ""), let url = URL(string: provider.defaultBaseURL) else { break }
            let config = CloudLLM.Config(provider: provider, key: parts[safe: 2], model: parts[safe: 3] ?? provider.suggestedModel, baseURL: url)
            Task {
                do { log("CLOUD ok: " + (try await CloudLLM.chat(config, system: "", user: "Say hi", images: [], json: false, quick: true))) }
                catch { log("CLOUD error: \(error.localizedDescription)") }
                do { log("CLOUD models: \(try await CloudLLM.models(config).prefix(5))") }
                catch { log("CLOUD models error: \(error.localizedDescription)") }
            }
        case "agentwords": // what each running Claude Code session last said (read-only)
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = obj["sessionId"] as? String, let cwd = obj["cwd"] as? String else { continue }
                log("WORDS \((cwd as NSString).lastPathComponent): \(AgentReply.lastWords(sessionID: id, cwd: cwd)?.prefix(140) ?? "nil")")
            }
        case "energychannels": // every channel in IOReport's Energy Model group, with watts over 1s
            Task.detached {
                guard let reader = EnergyReader() else { return }
                _ = reader.sampleAll()
                Thread.sleep(forTimeInterval: Double(parts[safe: 1] ?? "") ?? 1)
                let all = reader.sampleAll().sorted { $0.value > $1.value }
                log("ENERGY " + all.map { String(format: "%@=%.3fW", $0.key, $0.value) }.joined(separator: " | "))
            }
        case "smcpower": // every SMC key starting with P, and its value
            Task.detached {
                guard let smc = SMCReader() else { return log("SMC unavailable") }
                let keys = smc.allKeys().filter { $0.hasPrefix("P") }
                log("SMCP " + keys.compactMap { k in smc.value(k).map { String(format: "%@=%.2f", k, $0) } }.joined(separator: " "))
            }
        case "bright": // bright [value]: logs the display brightness, or sets it (0–1)
            let controls = ControlsService.shared
            controls.refresh()
            if let v = Float(parts[safe: 1] ?? "") { controls.setBrightness(v) }
            log("BRIGHT \(controls.brightness)")
        case "suggestrun": // runs the highlighted suggestion if it's a command
            if case .command(let command)? = SearchSuggestions.shared.current { CommandCenter.shared.run([command]) }
            log("SUGGESTIONS " + SearchSuggestions.shared.items.map { if case .command(let c) = $0 { c.title } else { $0.id } }.joined(separator: " | "))
        case "aicmd": // aicmd <index>: runs an AI Command on the selection
            let commands = AICommandStore.shared.commands
            if let i = Int(parts[safe: 1] ?? ""), commands.indices.contains(i) { AICommandRunner.run(commands[i]) }
        case "compact": // compact <item> [0]: a pinned Glance's compact form on or off
            if let item = LiveItem(rawValue: parts[safe: 1] ?? "") { LiveActivities.shared.update(item) { $0.compact = parts[safe: 2] != "0" } }
        case "codeshot": // codeshot <path>: sample code in each language, highlighted
            let samples: [(String?, String)] = [
                ("python", "# average of the prices\ndef average(prices: list[float]) -> float:\n    if not prices:\n        return 0.0  # empty CSV\n    return sum(prices) / len(prices)\n\n@dataclass\nclass Item:\n    name: str = \"widget\""),
                ("swift", "@MainActor\nfunc load(_ url: URL) async throws -> [Price] {\n    let (data, _) = try await URLSession.shared.data(from: url)\n    return try JSONDecoder().decode([Price].self, from: data) // 3 tries\n}"),
                (nil, "const total = items.reduce((sum, x) => sum + x.price, 0);\nconsole.log(`Total: ${total.toFixed(2)}`);"),
                ("json", "{\"name\": \"notch\", \"version\": 2, \"beta\": true, \"tags\": [\"mac\", null]}"),
                ("bash", "#!/bin/zsh\n# rebuild and install\nexport APP=$HOME/Applications\nswift build -c release && ./build.sh install"),
            ]
            let view = VStack(alignment: .leading, spacing: 10) {
                ForEach(samples.indices, id: \.self) { i in
                    Text(SyntaxHighlighter.highlight(samples[i].1, language: samples[i].0))
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(10)
                        .frame(width: 560, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                }
            }
            .padding(14)
            .background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: parts[safe: 1] ?? "/tmp/code.png"))
            }
        case "pins": // pins item,item… (empty clears); saves nothing else
            let items = (parts[safe: 1] ?? "").split(separator: ",").compactMap { LiveItem(rawValue: String($0)) }
            LiveActivities.shared.slots.forEach { LiveActivities.shared.unpin($0.item) }
            items.forEach { LiveActivities.shared.pin($0) }
        case "speedtest": SpeedTest.shared.start()
        case "clipshown": // clipshown <text|link|image|files>: how many clips that filter shows
            let kind = ClipboardHistory.Clip.Kind(rawValue: parts[safe: 1] ?? "")
            log("CLIPSHOWN \(parts[safe: 1] ?? "all") \(ClipboardHistory.shared.shown(matching: "", kind: kind).count)")
        case "convops": // convops <path>: logs the conversions offered for that file
            let url = URL(fileURLWithPath: parts.dropFirst().joined(separator: " "))
            log("CONVOPS \(url.lastPathComponent): " + MediaConverter.operations(for: [url]).map(\.rawValue).joined(separator: ","))
        case "convjobs": // logs every conversion job's state
            for job in MediaConverter.shared.jobs { log("CONVJOB \(job.source.lastPathComponent) \(job.operation.rawValue) \(job.state)") }
        case "convertsave": // convertsave <copy|same|replace> <operation> <path>
            let saving: MediaConverter.Saving = parts[safe: 1] == "replace" ? .replace : parts[safe: 1] == "same" ? .sameName : .copy
            if let op = MediaConverter.Operation(rawValue: parts[safe: 2] ?? "") {
                MediaConverter.shared.convert([URL(fileURLWithPath: parts.dropFirst(3).joined(separator: " "))], op, saving: saving)
            }
        case "convert": // convert <operation> <path>
            if let op = MediaConverter.Operation(rawValue: parts[safe: 1] ?? "") {
                MediaConverter.shared.convert([URL(fileURLWithPath: parts.dropFirst(2).joined(separator: " "))], op)
            }
        case "ytdl": if let url = URL(string: parts[safe: 1] ?? "") { VideoDownloader.shared.download(url, format: parts[safe: 2] == "audio" ? .audio : .video, height: Int(parts[safe: 2] ?? "")) }
        case "ports": PortScanner.shared.refresh(); PortScanner.shared.listOpen = parts[safe: 1] != "0"
        case "uninstall": AppUninstaller.shared.inspect(URL(fileURLWithPath: parts.dropFirst().joined(separator: " ")))
        case "peek":
            ActivityCenter.shared.show(parts[safe: 1] == "download" ? .download(name: "Report-final.pdf")
                                                                    : .timer(message: "Short break · 5 min"), for: 5)
        case "settings": SettingsWindowController.shared.show(pane: SettingsPane(rawValue: parts.dropFirst().joined(separator: " ")))
        case "pull": AssistantStore.shared.pullModel(parts[safe: 1])
        case "cancelpull": AssistantStore.shared.cancelPull()
        case "shelfadd": // shelfadd <path…>: a quick drop, as if dragged onto the notch
            ShelfStore.shared.add(parts.dropFirst().map { URL(fileURLWithPath: $0) })
        case "shelfclearquick": ShelfStore.shared.remove(ShelfStore.shared.stack)
        case "shelfselect": // shelfselect <n>: picks the first n files on the shelf (0 lets go)
            ShelfStore.shared.selection = Set(ShelfStore.shared.shown.prefix(Int(parts[safe: 1] ?? "") ?? 0).map(\.id))
        case "convertpicker": ShelfStore.shared.convertPicker = parts.count > 1 ? parts.dropFirst().map { URL(fileURLWithPath: $0) } : nil
        case "replytest": // a banner with a Reply box, like a chat app's (replies are logged)
            Notifier.debugReplyBanner(from: parts.dropFirst().joined(separator: " "))
        case "fakenotify": NotificationMirror.shared.debugFake()
        case "fakereply": if let item = NotificationMirror.shared.recent.first { NotchPresenter.shared.presentReply(to: item) }
        case "notifydump": NotificationMirror.shared.debugDump()
        case "notifyscan": NotificationMirror.shared.scan()
        case "prompter": // prompter start|stop|pause|voice
            switch parts[safe: 1] {
            case "start":
                if Teleprompter.shared.script.isEmpty {
                    Teleprompter.shared.script = "Good morning everyone, and thanks for joining. Today I want to walk you through three things: where the launch stands, what we learned from the beta, and what we need from each team over the next two weeks. Let's start with the launch. We are on track for the twenty-first, and the last open question is pricing for teams."
                }
                Teleprompter.shared.start()
            case "pause": Teleprompter.shared.togglePause()
            default: Teleprompter.shared.stop()
            }
        case "clipselect": // clipselect <n>: picks the first n clips
            ClipboardHistory.shared.selection = Set(ClipboardHistory.shared.clips.prefix(Int(parts[safe: 1] ?? "") ?? 0).map(\.id))
        case "ql": QuickLookPreview.shared.show(parts.dropFirst().map { URL(fileURLWithPath: $0) })
        case "call": MeetingMonitor.shared.debugSimulate(parts[safe: 1] != "0")
        case "convertall": // convertall <operation> [path…]: those files (else every file on the shelf), as one batch
            let files = parts.count > 2 ? parts.dropFirst(2).map { URL(fileURLWithPath: $0) } : ShelfStore.shared.items.map(\.url)
            if let op = MediaConverter.Operation(rawValue: parts[safe: 1] ?? "") { MediaConverter.shared.convert(files, op) }
        case "stackhover": c.viewModel.stackHovered = parts[safe: 1] != "0"
        case "glancepeek": // glancepeek <item> (none: ends it): what resting the pointer on a Glance shows
            if let item = LiveItem(rawValue: parts[safe: 1] ?? "") { c.viewModel.hoverGlance(item, true) } else { c.viewModel.endGlancePeek() }
            log("GLANCEMIDX \(c.viewModel.glanceMidX.map { "\($0.key.rawValue)=\(Int($0.value))" }.sorted())")
        case "focus": // what the Focus Glance sees
            FocusMonitor.shared.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let f = FocusMonitor.shared
                DebugHooks.log("FOCUS readable=\(f.readable) current=\(f.current.map { "\($0.name) \($0.symbol) since=\(String(describing: $0.since)) until=\(String(describing: $0.until))" } ?? "none") shortcut=\(f.shortcut?.name ?? "-")")
            }
        case "shelfdrop": // shelfdrop <path>: takes that file's item off the Shelf (the file stays)
            let path = parts.dropFirst().joined(separator: " ")
            ShelfStore.shared.remove(ShelfStore.shared.items.filter { $0.url.path == path })
            log("SHELF " + ShelfStore.shared.items.suffix(3).map { $0.url.path }.joined(separator: " ; "))
        case "shelfname": // shelfname <path>: its made-up name and the file it would leave as
            let url = URL(fileURLWithPath: parts.dropFirst().joined(separator: " "))
            log("SHELFNAME on=\(ShelfNames.isOn(for: url)) alias=\(ShelfNames.alias(for: url)) out=\(ShelfNames.outgoing(url).path)")
        case "clipdrop": // clipdrop <text>: deletes clipboard-history entries with exactly that text
            let text = parts.dropFirst().joined(separator: " ")
            let gone = ClipboardHistory.shared.clips.filter { $0.text == text }
            gone.forEach { ClipboardHistory.shared.delete($0) }
            log("CLIPDROP \(gone.count)")
        case "shotcatch": // shotcatch <path>|<path>…: screenshots arriving at once (twins make one)
            ScreenshotWatcher.shared.debugCatch(parts.dropFirst().joined(separator: " ").split(separator: "|").map { URL(fileURLWithPath: String($0)) })
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                DebugHooks.log("SHELF " + ShelfStore.shared.items.suffix(3).map { $0.url.path }.joined(separator: " ; "))
            }
        case "suggest": SearchSuggestions.shared.update(parts.dropFirst().joined(separator: " "))
        case "suggestlog": // suggestlog <query…>: what the list offers for it
            SearchSuggestions.shared.update(parts.dropFirst().joined(separator: " "))
            log("SUGGEST " + SearchSuggestions.shared.items.map { item in
                if case .command(let c) = item { return "[\(c.title) | \(c.subtitle ?? "")]" }
                return "\(item)".prefix(40).description
            }.joined(separator: " "))
        case "shortcuts": // shortcuts [glance <name…>]: the Shortcuts app's list, or one added to/removed from the Glance
            let sc = ShortcutsApp.shared
            if parts[safe: 1] == "glance", let s = sc.all.first(where: { $0.name.lowercased() == parts.dropFirst(2).joined(separator: " ").lowercased() }) {
                sc.toggleGlance(s)
            }
            log("SHORTCUTS \(sc.all.count): \(sc.all.prefix(8).map { "\($0.name)\($0.folder.map { " [\($0)]" } ?? "")" }) glance=\(sc.glanceShortcuts.map(\.name))")
        case "spectrum":
            let sp = AudioSpectrum.shared
            log("spectrum live=\(sp.isLive) permitted=\(AudioSpectrum.permitted) playing=\(MediaController.shared.isPlaying) app=\(MediaController.shared.bundleID ?? "-") levels=\(sp.levels.map { String(format: "%.2f", $0) })")
        case "visual": parts[safe: 1] == "remove" ? VisualSearch.shared.remove() : VisualSearch.shared.install()
        case "lookalike":
            let q = parts.dropFirst().joined(separator: " ")
            for hit in ImageIndexStore.shared.visualSearch(q, limit: 5) {
                log(String(format: "lookalike %.3f z%.1f %@", hit.similarity, hit.standout, hit.url.lastPathComponent))
            }
        case "taildrop": TaildropService.shared.offer([URL(fileURLWithPath: parts.dropFirst().joined(separator: " "))])
        case "mirror": c.viewModel.mirror = parts[safe: 1] != "0"
        case "selfupdate": // checks NotchApp's own releases, then logs what it found
            AppUpdater.shared.check()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { log("SELFUPDATE \(AppUpdater.currentVersion) → \(AppUpdater.shared.state)") }
        case "updates":
            if parts[safe: 1] == "list" { UpdateChecker.shared.listOpen = true } else { UpdateChecker.shared.check() }
        case "awake":
            if let m = Int(parts[safe: 1] ?? "") { KeepAwake.shared.start(.minutes(m)) } else { KeepAwake.shared.stop() }
        case "awakedisplay": AppSettings.shared.keepAwakeDisplay = parts[safe: 1] != "0"   // live, mid-session
        case "appactions": // what the row under the empty bar offers for the app in front
            let a = AppActions.shared
            log("APPACTIONS \(a.context.map { "\($0.appName) \($0.kind) url=\($0.url?.absoluteString ?? "-") file=\($0.filePath ?? "-") sel=\($0.selection?.prefix(40) ?? "-") editable=\($0.selectionEditable)" } ?? "none") → \(a.items.map(\.title))")
        case "apprun", "appstar": // apprun|appstar <title…>: runs (or stars as a Glance) an app action by title
            let title = parts.dropFirst().joined(separator: " ").lowercased()
            if let command = AppActions.shared.items.first(where: { $0.title.lowercased() == title }) {
                if parts[0] == "apprun" { CommandCenter.shared.run([command]) } else { AppActions.shared.toggleStar(command) }
            }
            log("APPSTARS \(AppActions.shared.stars) glance=\(AppActions.shared.glanceActions.map(\.title))")
        case "meeting": MeetingMonitor.shared.debugSimulate(parts[safe: 1] != "end")
        case "golden": log("GOLDEN \(GoldenHour.now().map { "\($0.text) golden=\($0.golden) near=\($0.near) \($0.detail)" } ?? "nil") days=\(TodayWeather.shared.report?.days.prefix(2).map { "\($0.sunrise.map(String.init(describing:)) ?? "-")/\($0.sunset.map(String.init(describing:)) ?? "-")" } ?? [])")
        case "close": c.viewModel.close()
        case "hover": c.viewModel.isHovering = parts.count > 1 ? parts[1] == "1" : true
        case "volume": ActivityCenter.shared.show(.volume(level: Float(parts[safe: 1] ?? "0.6") ?? 0.6, muted: false), for: 5)
        case "brightness": ActivityCenter.shared.show(.brightness(level: Float(parts[safe: 1] ?? "0.4") ?? 0.4), for: 5)
        case "charging": ActivityCenter.shared.show(.charging(level: BatteryMonitor.shared.level), for: 5)
        case "meeting": ActivityCenter.shared.show(.meeting(title: "Design review", minutes: 5, color: .systemOrange), for: 6)
        case "screenshot": ActivityCenter.shared.show(.screenshot(count: 1), for: 5)
        case "key": // key <keyCode> [cmd|shift|ctrl|opt…] [chars]: a key press posted to this notch's own window only
            guard let code = UInt16(parts[safe: 1] ?? ""), let window = c.panelContentView?.window else { break }
            var flags: NSEvent.ModifierFlags = []
            var chars = ""
            for word in parts.dropFirst(2) {
                switch word {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "ctrl": flags.insert(.control)
                case "opt": flags.insert(.option)
                default: chars = word
                }
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
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

/// `sim <event>`: shows what a real event would, through the same code, for screenshots.
@MainActor
enum DebugSimulator {
    static func run(_ event: String, _ args: [String]) {
        switch event {
        case "reply": // a made-up message's reply box; nothing is sent unless Send is clicked
            NotchPresenter.shared.present(.message(.init(id: "debug", app: "Messages", bundleID: "com.apple.MobileSMS", title: "Alex",
                                                         subtitle: "", body: "Are we still on for dinner tonight?", date: Date(), canReply: false)))
        case "meeting":
            ActivityCenter.shared.show(.meeting(title: "Design review", minutes: 3, color: .systemPurple), for: 8)
            let link = MeetingLinks.Link(url: URL(string: "https://zoom.us/j/123456789")!, service: "Zoom")
            NotchPresenter.shared.offer(Prompt(icon: "video.fill", tint: .systemPurple, title: "Design review",
                                               detail: "Starts in 3 min · Zoom",
                                               actions: [.init(title: "Join Zoom", primary: true) { MeetingLinks.join(link) }]), peek: false)
        case "devserver":
            NotchPresenter.shared.offer(Prompt(icon: "server.rack", tint: .systemGreen, title: "localhost:5173 is up", detail: "node · notch-site",
                                               actions: [.init(title: "Copy URL") {}, .init(title: "Open", primary: true) {}]))
        case "offline": ConnectionWatcher.alertOffline()
        case "online": ConnectionWatcher.alertOnline("Home Wi-Fi")
        case "vpnup": ConnectionWatcher.alertVPN("ProtonVPN", up: true, detail: "Zurich, Switzerland", fullTunnel: true)
        case "vpndown": ConnectionWatcher.alertVPN("ProtonVPN", up: false, detail: nil, fullTunnel: true)
        case "ip": ConnectionWatcher.alertIP(VPNMonitor.Exit(ip: "185.159.157.12", city: "Zurich", country: "Switzerland", countryCode: "CH"))
        case "battery":
            ActivityCenter.shared.show(.notice(title: "AirPods Pro · 15%", detail: "Battery low", icon: "airpodspro", tone: .warning), for: 5)
        case "mic":
            ActivityCenter.shared.show(.notice(title: "Microphone on", detail: "Zoom", icon: "mic.fill", tone: .info), for: 5)
        case "agentdone":
            ActivityCenter.shared.show(.notice(title: "Claude Code finished", detail: "NotchApp", icon: "sparkles.rectangle.stack.fill"), for: 5)
        case "agentwaiting":
            ActivityCenter.shared.show(.notice(title: "Claude Code needs you", detail: "NotchApp", icon: "hand.raised.fill", tone: .warning), for: 5)
        case "lowdisk":
            ActivityCenter.shared.show(.notice(title: "8.2 GB free", detail: "Low disk space · Tools → Cleaner",
                                               icon: "externaldrive.fill.badge.exclamationmark", tone: .warning), for: 5)
        case "speed":
            ActivityCenter.shared.show(.notice(title: "↓ 748  ↑ 118 Mbps", detail: "Speed test", icon: "speedometer"), for: 5)
        case "converted":
            ActivityCenter.shared.show(.notice(title: "Compress Video", detail: "48.2 MB → 9.6 MB (−80%)", icon: "wand.and.stars"), for: 5)
        case "convertfail":
            ActivityCenter.shared.show(.notice(title: "Conversion failed", detail: "Clip.mov", icon: "wand.and.stars", tone: .warning), for: 5)
        default:
            DebugHooks.log("sim: unknown event \(event)")
        }
    }
}
