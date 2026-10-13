import AppKit

/// The actions each app gets beyond the selection: a page in a browser (and the site it's on), an
/// email or a chat, a note or a draft, code, a terminal, Finder's selected files, and creative
/// apps' own exports and renders.
///
/// Menu-backed actions only appear when the app's menu really has that item, enabled: nothing
/// shows that would do nothing. Questions about the window only appear with a model ready and
/// screen questions on.
@MainActor
enum AppPack {
    static func actions(for c: AppContext, screen: Bool) -> [Command] {
        let id = c.bundleID?.lowercased() ?? ""
        let kit = Kit(c: c, screen: screen)
        // An app of its own first; else what its kind of app gets.
        if let own = creative(id, kit) ?? media(id, kit) ?? calls(id, kit) { return own.compactMap { $0 } }
        switch c.kind {
        case .browser: return browser(kit)
        case .mail:
            return [kit.ask("Summarize email", "Summarize this email in two or three short bullet points.", "text.alignleft"),
                    kit.ask("Draft a reply", "Draft a short, friendly reply to this email, ready to send. Write only the reply.", "arrowshape.turn.up.left"),
                    kit.plan("To calendar & tasks", "Add the dates and to-dos in this email to my calendar and tasks.", "calendar.badge.plus")]
                .compactMap { $0 }
        case .chat:
            var out = [kit.ask("Catch me up", "Summarize this conversation: what was said, and anything waiting on me.", "text.bubble"),
                       kit.ask("Draft a reply", "Draft a short reply to the latest message, in the same tone. Write only the reply.", "arrowshape.turn.up.left")]
            if id.hasPrefix("com.hnc.discord") {
                // Discord's own shortcuts (defaults on the Mac), sent to it.
                out.insert(kit.keys("discord.mute", "Mute", "mic.slash", key: 46, [.maskCommand, .maskShift]), at: 0)
                out.insert(kit.keys("discord.deafen", "Deafen", "headphones", key: 2, [.maskCommand, .maskShift]), at: 1)
            }
            return out.compactMap { $0 }
        case .notes:
            return [kit.ask("Summarize note", "Summarize this note in a few short bullet points.", "text.alignleft"),
                    kit.plan("To-dos to Tasks", "Add the to-dos and action items in this note to my tasks.", "checklist")]
                .compactMap { $0 }
        case .writing:
            return [kit.ask("Proofread", "Proofread the document on screen: list typos, grammar slips and clumsy sentences, each with its fix. Don't rewrite anything else.", "checkmark.seal"),
                    kit.ask("Summarize", "Summarize this document in a few short bullet points.", "text.alignleft"),
                    kit.menu("Export PDF", "doc.richtext", [["Export To", "PDF"], ["Export as PDF"], ["Save as PDF"]])]
                .compactMap { $0 }
        case .terminal:
            return [kit.ask("Explain the error", "Explain the most recent error or failure in this terminal, and how to fix it.", "exclamationmark.bubble"),
                    kit.ask("What happened?", "In a few lines, what did the last command do, and did it work?", "questionmark.bubble")]
                .compactMap { $0 }
        case .code:
            return [kit.ask("Explain the error", "Explain the error or warning on screen, and how to fix it.", "exclamationmark.bubble"),
                    kit.ask("Explain this code", "Explain what the code on screen does, briefly.", "curlybraces")]
                .compactMap { $0 }
        case .finder:
            return finder(kit)
        case .other:
            return []
        }
    }

    // MARK: - Creative apps

    /// Video, audio, photo and design apps: the export or render you'd otherwise dig through menus for.
    private static func creative(_ id: String, _ kit: Kit) -> [Command?]? {
        switch id {
        case "com.apple.finalcut", "com.apple.finalcuttrial":
            return [kit.menu("Export master file", "square.and.arrow.up", [["Share", "Master File"], ["Share", "Export File"]], shortcut: "⌘E"),
                    kit.menu("Save current frame", "photo", [["Share", "Save Current Frame"]]),
                    kit.menu("Render all", "gearshape.2", [["Render All"]], shortcut: "⌃⇧R"),
                    kit.menu("Background tasks", "list.bullet.rectangle", [["Background Tasks"]], shortcut: "⌘9")]
        case "com.apple.imovieapp":
            return [kit.menu("Export file", "square.and.arrow.up", [["Share", "File"]], shortcut: "⌘E"),
                    kit.menu("Save current frame", "photo", [["Share", "Image"]])]
        case _ where id.hasPrefix("com.adobe.premierepro"):
            return [kit.menu("Export media", "square.and.arrow.up", [["Export", "Media"]], shortcut: "⌘M"),
                    kit.menu("Render in to out", "gearshape.2", [["Render In to Out"]])]
        case _ where id.hasPrefix("com.blackmagic-design.davinciresolve"):
            return [kit.menu("Quick export", "square.and.arrow.up", [["Quick Export"]])]
        case "com.apple.logic10", "com.apple.logic.pro":
            return [kit.menu("Bounce", "waveform", [["Bounce", "Project or Section"]], shortcut: "⌘B")]
        case "com.apple.garageband10":
            return [kit.menu("Export song", "waveform", [["Export Song to Disk"]])]
        case _ where id.hasPrefix("com.ableton.live"):
            return [kit.menu("Export audio", "waveform", [["Export Audio/Video"]], shortcut: "⇧⌘R")]
        case _ where id.hasPrefix("com.adobe.photoshop"):
            return [kit.menu("Quick export PNG", "square.and.arrow.up", [["Export", "Quick Export as PNG"]]),
                    kit.menu("Export as", "square.and.arrow.up.on.square", [["Export", "Export As"]], shortcut: "⌥⇧⌘W"),
                    kit.menu("Image size", "arrow.up.left.and.arrow.down.right", [["Image Size"]], shortcut: "⌥⌘I")]
        case _ where id.hasPrefix("com.adobe.illustrator"):
            return [kit.menu("Export for screens", "square.and.arrow.up", [["Export for Screens"]], shortcut: "⌥⌘E"),
                    kit.menu("Export as", "square.and.arrow.up.on.square", [["Export", "Export As"]])]
        case _ where id.hasPrefix("com.adobe.lightroom"):
            return [kit.menu("Export with previous", "square.and.arrow.up", [["Export with Previous"]], shortcut: "⌥⇧⌘E"),
                    kit.menu("Export", "square.and.arrow.up.on.square", [["Export"]], shortcut: "⇧⌘E")]
        case "com.figma.desktop":
            return [kit.menu("Copy as PNG", "photo.on.rectangle", [["Copy as PNG"]], shortcut: "⇧⌘C"),
                    kit.menu("Export", "square.and.arrow.up", [["Export"]], shortcut: "⇧⌘E")]
        case "com.bohemiancoding.sketch3":
            return [kit.menu("Copy as PNG", "photo.on.rectangle", [["Copy as PNG"]]),
                    kit.menu("Export", "square.and.arrow.up", [["Export"]])]
        case _ where id.hasPrefix("com.seriflabs.affinity") || id.hasPrefix("com.canva.affinity"):
            return [kit.menu("Export", "square.and.arrow.up", [["Export"]])]
        case "com.pixelmatorteam.pixelmator.x":
            return [kit.menu("Quick export", "square.and.arrow.up", [["Quick Export"]]),
                    kit.menu("Export", "square.and.arrow.up.on.square", [["Export"]])]
        case "com.apple.keynote", "com.apple.iwork.keynote", "com.apple.numbers", "com.apple.iwork.numbers":
            return [kit.menu("Export PDF", "doc.richtext", [["Export To", "PDF"]])]
        default:
            return nil
        }
    }

    /// Players: the song or the frame.
    private static func media(_ id: String, _ kit: Kit) -> [Command?]? {
        switch id {
        case "com.spotify.client":
            return [kit.perform("spotify.link", "Copy song link", nil, "link") { copySpotifyLink(); return nil },
                    kit.keys("spotify.like", "Like song", "heart", key: 11, [.maskAlternate, .maskShift])]
        case "com.apple.music":
            return [kit.menu("Favorite", "star", [["Favorite"], ["Love"]]),
                    kit.menu("Go to current song", "music.note", [["Go to Current Song"]], shortcut: "⌘L")]
        case "com.colliderli.iina":
            return [kit.menu("Screenshot frame", "camera", [["Take a Screenshot"], ["Screenshot"]])]
        case "com.apple.quicktimeplayerx":
            return [kit.menu("Trim", "scissors", [["Trim"]], shortcut: "⌘T")]
        default:
            return nil
        }
    }

    /// Video calls: mute and camera without hunting for the window's controls.
    private static func calls(_ id: String, _ kit: Kit) -> [Command?]? {
        guard id == "us.zoom.xos" else { return nil }
        return [kit.menu("Mute", "mic.slash", [["Mute Audio"], ["Unmute Audio"]], shortcut: "⇧⌘A", key: "zoom.audio", ownTitle: true),
                kit.menu("Video", "video", [["Stop Video"], ["Start Video"]], shortcut: "⇧⌘V", key: "zoom.video", ownTitle: true),
                kit.menu("Share screen", "rectangle.on.rectangle", [["Share Screen"]], shortcut: "⇧⌘S")]
    }

    // MARK: - Browsers

    private static func browser(_ kit: Kit) -> [Command] {
        var out: [Command?] = []
        guard let url = kit.c.url else {
            return [kit.ask("Summarize page", "Summarize this page in a few short bullet points.", "text.alignleft")].compactMap { $0 }
        }
        let title = pageTitle(kit.c)
        let host = (url.host() ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let parts = url.pathComponents.filter { $0 != "/" }

        // The site first: what's specific to it beats what every page gets.
        if VideoDownloader.isAvailable, isVideoPage(url) {
            let quality = AppSettings.shared.videoQuality
            out.append(Command(action: .downloadMedia(url, .video, height: quality > 0 ? quality : nil),
                               title: "Download video", subtitle: title, icon: "arrow.down.circle", verb: "Download"))
            out.append(Command(action: .downloadMedia(url, .audio, height: nil),
                               title: "Download audio", subtitle: title, icon: "waveform.circle", verb: "Download"))
        }
        if host == "meet.google.com", parts.count == 1 {
            out.append(kit.keys("meet.mute", "Mute", "mic.slash", key: 2, [.maskCommand]))
            out.append(kit.keys("meet.camera", "Camera", "video.slash", key: 14, [.maskCommand]))
        }
        if host == "github.com", parts.count >= 2 {
            let repo = "\(parts[0])/\(parts[1])"
            if parts.count >= 4, ["pull", "issues"].contains(parts[2]), Int(parts[3]) != nil {
                let ref = "\(repo)#\(parts[3])"
                out.append(kit.perform("github.ref", "Copy \(parts[2] == "pull" ? "PR" : "issue") ref", ref, "number") { copy(ref); return "Copied \(ref)" })
            }
            let clone = "git clone https://github.com/\(repo).git"
            out.append(kit.perform("github.clone", "Copy clone command", clone, "terminal") { copy(clone); return "Copied clone command" })
        }
        if host == "docs.google.com", parts.first == "document" {
            out.append(kit.ask("Proofread", "Proofread the document on screen: list typos, grammar slips and clumsy sentences, each with its fix. Don't rewrite anything else.", "checkmark.seal"))
        }

        out.append(kit.ask("Summarize page", "Summarize this page in a few short bullet points.", "text.alignleft"))
        out.append(kit.perform("page.copy", "Copy link", url.absoluteString, "link") { copy(url.absoluteString); return "Copied link" })
        if AppSettings.shared.shelfEnabled {
            out.append(kit.perform("page.shelf", "Save to Shelf", title, "tray.and.arrow.down") {
                ShelfStore.shared.addLink(url, title: title); return "Saved to Shelf"
            })
        }
        if AppSettings.shared.tasksEnabled {
            out.append(kit.perform("page.task", "Read later", "Adds “\(title)” to Tasks", "checkmark.circle") {
                TaskStore.shared.add(TaskItem(title: "Read \(title)", link: url, linkKind: .web)); return "Added to Tasks"
            })
        }
        out.append(kit.perform("page.markdown", "Copy as Markdown", "[\(title)](\(url.absoluteString))", "text.badge.plus") {
            copy("[\(title)](\(url.absoluteString))"); return "Copied Markdown link"
        })
        return out.compactMap { $0 }
    }

    // MARK: - Files

    /// Finder: what the selected files can become (a cutout, a GIF, a smaller video), then where
    /// they can go. With nothing selected, the folder's path.
    private static func finder(_ kit: Kit) -> [Command] {
        let files = kit.c.files
        if kit.c.needsFinderPermission {
            return [kit.perform("finder.permission", "See selected files", "Lets NotchApp ask Finder what's selected", "folder.badge.questionmark") {
                Task.detached {
                    _ = AppContext.automationPermission("com.apple.finder", ask: true)
                    await MainActor.run { NotchPresenter.shared.primary?.open(tab: .ask, takeKeyboard: false, reason: .system); AppActions.shared.prepare() }
                }
                return "Asking Finder…"
            }]
        }
        guard !files.isEmpty else {
            guard let path = kit.c.filePath else { return [] }
            return [kit.perform("folder.copy", "Copy folder path", path, "doc.on.doc") { copy(path); return "Copied path" }]
        }
        var out = fileActions(files, kit)
        if AppSettings.shared.shelfEnabled {
            out.append(kit.perform("files.shelf", "Put on Shelf", names(files), "tray.and.arrow.down") {
                ShelfStore.shared.add(files); return "Added to Shelf"
            })
        }
        out.append(kit.perform("files.airdrop", "AirDrop", names(files), "airplayaudio") {
            NotchPresenter.shared.primary?.close()
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: files)
            return nil
        })
        let paths = files.map(\.path).joined(separator: "\n")
        out.append(kit.perform("files.path", files.count == 1 ? "Copy path" : "Copy paths", names(files), "doc.on.doc") {
            copy(paths); return files.count == 1 ? "Copied path" : "Copied \(files.count) paths"
        })
        return out
    }

    /// An open document in any other app (a photo in Preview, a video in IINA): the same
    /// conversions, then the Shelf and Finder.
    static func documentActions(_ c: AppContext) -> [Command] {
        guard c.kind != .finder, let path = c.filePath, FileManager.default.fileExists(atPath: path) else { return [] }
        let url = URL(fileURLWithPath: path)
        let kit = Kit(c: c, screen: false)
        var out = Array(fileActions([url], kit).prefix(2))
        if AppSettings.shared.shelfEnabled {
            out.append(kit.perform("doc.shelf", "Put on Shelf", url.lastPathComponent, "tray.and.arrow.down") {
                ShelfStore.shared.add([url]); return "Added to Shelf"
            })
        }
        out.append(kit.perform("doc.reveal", "Show in Finder", url.lastPathComponent, "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url]); return nil
        })
        return out
    }

    /// What files of one kind can become, most wanted first.
    private static func fileActions(_ files: [URL], _ kit: Kit) -> [Command] {
        let ops = MediaConverter.operations(for: files)
        var out: [Command] = []
        let images = files.allSatisfy { MediaConverter.kind(of: $0) == .image }
        if images, files.count <= 10 {
            out.append(kit.perform("files.cutout", "Remove background", names(files), "person.crop.rectangle") {
                Cutout.run(files); return nil
            })
        }
        // The two most wanted for the kind of file (the list puts them first), then every other
        // conversion behind "Convert…" (the row has room for five).
        for op in ops.prefix(images ? 1 : 2) {
            out.append(kit.perform("files." + op.rawValue, chipTitle(op), names(files), icon(op)) {
                MediaConverter.shared.convert(files, op)
                return "\(op.title)…"
            })
        }
        if ops.count > (images ? 1 : 2) {
            out.append(kit.perform("files.convert", "Convert…", names(files), "wand.and.stars") {
                MediaConverter.shared.offer(files)
                return nil
            })
        }
        return out
    }

    /// Short names for the row ("Make GIF" rather than "Make a GIF").
    private static func chipTitle(_ op: MediaConverter.Operation) -> String {
        switch op {
        case .toGIF: "Make GIF"
        case .compressVideo: "Compress video"
        case .makeVertical: "Make vertical"
        case .normalizeLoudness: "Normalize loudness"
        case .youtubeThumbnail: "YouTube thumbnail"
        default: op.title.replacingOccurrences(of: "Convert to", with: "To")
        }
    }

    private static func icon(_ op: MediaConverter.Operation) -> String { op.symbol }

    // MARK: - Helpers

    /// Builds the commands for one app, so each pack reads as a list.
    struct Kit {
        let c: AppContext
        let screen: Bool

        /// A question about the window, answered in the notch.
        func ask(_ title: String, _ question: String, _ icon: String) -> Command? {
            guard screen else { return nil }
            return Command(action: .askScreen(question), title: title, subtitle: "Looks at \(c.appName)", icon: icon, verb: "Ask")
        }

        /// Tasks or events planned from what's in the window, shown for review before anything is added.
        func plan(_ title: String, _ request: String, _ icon: String) -> Command? {
            guard screen else { return nil }
            return Command(action: .planFromScreen(request), title: title, subtitle: "From what's in \(c.appName)", icon: icon, verb: "Plan")
        }

        /// One of the app's menu items, by its menus and title ("Share", "Master File"); nil when the
        /// app has no such item, or it's disabled right now. `ownTitle` shows the item's own words,
        /// for menu items that flip ("Mute Audio" / "Unmute Audio").
        @MainActor func menu(_ title: String, _ icon: String, _ candidates: [[String]], shortcut: String? = nil,
                             key: String? = nil, ownTitle: Bool = false) -> Command? {
            guard let ref = MenuSearch.shared.find(pid: c.pid, candidates, shortcut: shortcut) else { return nil }
            let shown = ownTitle ? ref.item.title.replacingOccurrences(of: "…", with: "") : title
            var command = Command(action: .menuItem(ref), title: shown,
                                  subtitle: ([ref.appName] + ref.item.path + [ref.item.title]).joined(separator: " › ")
                                      + (ref.item.shortcut.map { "  \($0)" } ?? ""),
                                  icon: icon, verb: "Run")
            command.key = key ?? "menu." + title.lowercased()
            return command
        }

        /// The app's own keyboard shortcut, sent to it.
        func keys(_ id: String, _ title: String, _ icon: String, key: CGKeyCode, _ flags: CGEventFlags) -> Command {
            let pid = c.pid
            var command = Command(action: .perform(.init(id: id) { KeyShortcut.send(key, flags, to: pid); return nil }),
                                  title: title, subtitle: "In \(c.appName)", icon: icon, verb: "Run")
            command.key = id
            return command
        }

        func perform(_ id: String, _ title: String, _ subtitle: String?, _ icon: String,
                     _ run: @escaping @MainActor () -> String?) -> Command {
            var command = Command(action: .perform(.init(id: id, run: run)), title: title, subtitle: subtitle, icon: icon, verb: "Run")
            command.key = id
            return command
        }
    }

    private static func names(_ files: [URL]) -> String {
        files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
    }

    /// The page's title from the window's, without the browser's name on the end.
    static func pageTitle(_ c: AppContext) -> String {
        var title = (c.windowTitle ?? "").trimmingCharacters(in: .whitespaces)
        for separator in [" - ", " — ", " – "] {
            if let range = title.range(of: separator + c.appName, options: [.backwards, .caseInsensitive]) { title = String(title[..<range.lowerBound]) }
        }
        if title.isEmpty { title = c.url?.host()?.replacingOccurrences(of: "www.", with: "") ?? "Page" }
        return title
    }

    static func isVideoPage(_ url: URL) -> Bool {
        let host = (url.host() ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let path = url.path.lowercased()
        switch host {
        case "youtube.com", "m.youtube.com": return path == "/watch" || path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
        case "youtu.be", "vimeo.com", "dailymotion.com", "twitch.tv": return path.count > 1
        case "x.com", "twitter.com": return path.contains("/status/")
        case "tiktok.com": return path.contains("/video/")
        case "instagram.com": return path.hasPrefix("/reel/") || path.hasPrefix("/p/")
        default: return false
        }
    }

    /// Spotify's link to the song playing ("spotify:track:…" made into an open.spotify.com link).
    private static func copySpotifyLink() {
        NotchPresenter.shared.primary?.close()
        Task {
            let result = await Shell.run("/usr/bin/osascript", ["-e", "tell application \"Spotify\" to return spotify url of current track"], timeout: 5)
            let uri = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = uri.split(separator: ":")
            guard result.ok, parts.count == 3 else {
                ActivityCenter.shared.show(.notice(title: "Couldn't get the song", detail: "Allow NotchApp to control Spotify", icon: "link", tone: .warning), for: 3)
                return
            }
            copy("https://open.spotify.com/\(parts[1])/\(parts[2])")
            ActivityCenter.shared.show(.notice(title: "Copied song link", detail: MediaController.shared.title, icon: "link", tone: .success), for: 2.5)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Sends an app its own keyboard shortcut: the notch closes first so the keys reach the app.
enum KeyShortcut {
    @MainActor static func send(_ key: CGKeyCode, _ flags: CGEventFlags, to pid: pid_t) {
        NotchPresenter.shared.primary?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
                    event?.flags = flags
                    event?.post(tap: .cghidEventTap)
                }
            }
        }
    }
}
