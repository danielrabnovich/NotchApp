import SwiftUI

/// Controls tab: volume and brightness sliders, and quick toggles and actions.
struct ControlsView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var controls: ControlsService
    @EnvironmentObject private var keepAwake: KeepAwake
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tiles: ControlTiles
    @EnvironmentObject private var ports: PortScanner

    var body: some View {
        if updates.listOpen {
            UpdatesList(onBack: { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { updates.listOpen = false } })
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else if ports.listOpen {
            PortsList(onBack: { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { ports.listOpen = false } })
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            controlsBody
                .transition(.opacity)
        }
    }

    private var controlsBody: some View {
        let shown = tiles.tiles.filter(\.isAvailable)
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 10) {
                PillSlider(icon: volumeIcon, value: controls.volume) { controls.setVolume($0) }
                if Brightness.isAvailable {
                    PillSlider(icon: "sun.max.fill", value: controls.brightness) { controls.setBrightness($0) }
                }
                Spacer(minLength: 0)
                if settings.updateChecks {
                    UpdatesCard { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { updates.listOpen = true } }
                }
                if let error = controls.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .onTapGesture { controls.clearError() }
                }
            }
            .frame(width: 210)

            if shown.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 20))
                    Text("Pick quick actions in Settings → Controls").font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { SettingsWindowController.shared.show(pane: .controls) }
            } else {
                // Rows spread over the column's height: the first level with the volume slider, the
                // last with the bottom of the left column.
                let columns = shown.count > 8 ? 6 : 4
                let rows = stride(from: 0, to: shown.count, by: columns).map { Array(shown[$0..<min($0 + columns, shown.count)]) }
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            ForEach(rows[i]) { action in
                                ActionTile(action: action, viewModel: viewModel).frame(maxWidth: .infinity)
                            }
                            ForEach(rows[i].count..<columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                        }
                        if i < rows.count - 1 { Spacer(minLength: 8) }
                    }
                }
                .frame(maxHeight: rows.count > 1 && settings.updateChecks ? .infinity : nil, alignment: .top)
            }
        }
        .onAppear {
            controls.refresh()
            SystemTweaks.shared.refresh()
        }
    }

    private var volumeIcon: String {
        controls.volume <= 0.001 ? "speaker.slash.fill" : controls.volume < 0.34 ? "speaker.wave.1.fill"
            : controls.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

extension ControlAction {
    /// Runs the action from a Glance beside the closed notch. Actions that need the screen to
    /// themselves (a screenshot, picking a colour, selecting text) wait for the click to finish.
    @MainActor func run() {
        let controls = ControlsService.shared, tweaks = SystemTweaks.shared
        let later: (@escaping @MainActor () -> Void) -> Void = { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated(work) }
        }
        switch self {
        case .wifi: controls.toggleWiFi()
        case .darkMode: controls.toggleDarkMode()
        case .mic: controls.toggleMic()
        case .screenshot: later { controls.screenshot() }
        case .colorPicker: later { controls.pickColor() }
        case .lockScreen: later { controls.lockScreen() }
        case .copyText: later { tweaks.copyTextFromScreen() }
        case .nightShift: tweaks.toggleNightShift()
        case .hiddenFiles: tweaks.toggleHiddenFiles()
        case .desktopIcons: tweaks.toggleDesktopIcons()
        case .flushDNS: tweaks.flushDNS()
        case .emptyTrash: controls.emptyTrash()
        case .speedTest: SpeedTest.shared.phase.isRunning ? SpeedTest.shared.cancel() : SpeedTest.shared.start()
        case .scanQR: later { QRScanner.scan() }
        case .captions: LiveCaptions.shared.toggleCaptions()
        case .keepAwake, .ports, .cleaner, .clipboard, .saveVideo: break // these open their own UI in the notch
        }
    }

    /// Tiles that lead to a feature which is switched off are hidden rather than dead.
    @MainActor var isAvailable: Bool {
        switch self {
        case .cleaner: AppSettings.shared.toolsEnabled
        case .clipboard: AppSettings.shared.clipboardHistory && AppSettings.shared.shelfEnabled
        case .nightShift: NightShift.isAvailable
        case .saveVideo: VideoDownloader.isAvailable
        case .captions: LiveCaptions.isSupported
        default: true
        }
    }
}

/// Live captions on and off, lit while they're on.
private struct CaptionsTile: View {
    @ObservedObject private var captions = LiveCaptions.shared

    var body: some View {
        ControlTile(icon: "captions.bubble.fill", title: "Captions", on: captions.showing, onTint: .indigo) {
            captions.toggleCaptions()
        }
        .help("What's playing, as text under the notch")
    }
}

/// One quick action, with its live state.
private struct ActionTile: View {
    let action: ControlAction
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var controls: ControlsService
    @EnvironmentObject private var tweaks: SystemTweaks
    @EnvironmentObject private var speed: SpeedTest
    @EnvironmentObject private var ports: PortScanner
    @EnvironmentObject private var videos: VideoDownloader

    var body: some View {
        switch action {
        case .wifi:
            ControlTile(icon: controls.wifiOn ? "wifi" : "wifi.slash", title: "Wi-Fi", on: controls.wifiOn) { controls.toggleWiFi() }
        case .keepAwake:
            KeepAwakeTile()
        case .darkMode:
            ControlTile(icon: "circle.lefthalf.filled", title: "Dark Mode", on: controls.darkMode) { controls.toggleDarkMode() }
        case .mic:
            ControlTile(icon: controls.micMuted ? "mic.slash.fill" : "mic.fill", title: controls.micMuted ? "Mic Off" : "Mic On",
                        on: controls.micMuted, onTint: .red) { controls.toggleMic() }
        case .screenshot:
            ControlTile(icon: "camera.viewfinder", title: "Screenshot", on: false) { closeThen { controls.screenshot() } }
        case .colorPicker:
            ControlTile(icon: "eyedropper", title: "Color Picker", on: false) { closeThen { controls.pickColor() } }
        case .lockScreen:
            ControlTile(icon: "lock.fill", title: "Lock Screen", on: false) { closeThen { controls.lockScreen() } }
        case .emptyTrash:
            ControlTile(icon: "trash.fill", title: controls.confirmingTrash ? "Click Again" : "Empty Trash",
                        on: controls.confirmingTrash, onTint: .red) { controls.emptyTrash() }
        case .copyText:
            ControlTile(icon: "text.viewfinder", title: "Copy Text", on: tweaks.recognizing) {
                closeThen { tweaks.copyTextFromScreen() }
            }
            .help("Drag over any part of the screen to copy the text in it")
        case .scanQR:
            ControlTile(icon: "qrcode.viewfinder", title: "Scan QR", on: false) { closeThen { QRScanner.scan() } }
                .help("Read a QR code anywhere on screen")
        case .captions:
            CaptionsTile()
        case .ports:
            ControlTile(icon: action.icon, title: "Ports", on: false) {
                ports.refresh()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { ports.listOpen = true }
            }
            .help("What's listening on which port")
        case .speedTest:
            ControlTile(icon: "speedometer", title: speedTitle, on: speed.phase.isRunning, onTint: ToolsPalette.good) {
                if speed.phase.isRunning { speed.cancel() } else { speed.start() }
            }
            .help(speed.phase.isRunning ? "Click to stop" : "Test your internet speed")
        case .cleaner:
            ControlTile(icon: "sparkles", title: "Cleaner", on: false) {
                CommandCenter.shared.show(.tools, pane: ToolsPane.cleaner.rawValue)
            }
        case .clipboard:
            ControlTile(icon: "doc.on.clipboard", title: "Clipboard", on: false) {
                CommandCenter.shared.show(.shelf, pane: ShelfPane.clipboard.rawValue)
            }
        case .hiddenFiles:
            ControlTile(icon: tweaks.hiddenFilesShown ? "eye" : "eye.slash", title: "Hidden Files", on: tweaks.hiddenFilesShown) {
                tweaks.toggleHiddenFiles()
            }
            .help("Show hidden files in Finder (restarts Finder)")
        case .desktopIcons:
            ControlTile(icon: "menubar.dock.rectangle", title: tweaks.desktopIconsHidden ? "Icons Hidden" : "Desktop Icons",
                        on: tweaks.desktopIconsHidden) { tweaks.toggleDesktopIcons() }
            .help("Hide desktop icons, for screen sharing (restarts Finder)")
        case .nightShift:
            ControlTile(icon: tweaks.nightShiftOn ? "moon.circle.fill" : "moon.circle", title: "Night Shift", on: tweaks.nightShiftOn,
                        onTint: Color(red: 1, green: 0.62, blue: 0.25)) { tweaks.toggleNightShift() }
        case .flushDNS:
            ControlTile(icon: "arrow.clockwise.circle", title: "Flush DNS", on: false) { tweaks.flushDNS() }
                .help("Clears the DNS cache (asks for your password)")
        case .saveVideo:
            ControlTile(icon: "arrow.down.circle.fill", title: videoTitle, on: videos.current != nil, onTint: .red) {
                guard let link = NSPasteboard.general.string(forType: .string).flatMap(VideoDownloader.webURL) else {
                    ActivityCenter.shared.show(.notice(title: "Copy a video link first", detail: "Save Video", icon: "link", tone: .warning), for: 3)
                    return
                }
                // Pick a quality; ⌥-click skips the menu and uses the default.
                if NSEvent.modifierFlags.contains(.option) { videos.download(link, format: .video) } else { videos.chooseQuality(for: link) }
            }
            .help("Downloads the link on your clipboard: pick a quality (⌥-click for your default)")
        }
    }

    private var videoTitle: String {
        guard let job = videos.current else { return "Save Video" }
        return job.state == .processing ? "Finishing…" : "\(Int((job.progress * 100).rounded()))%"
    }

    private var speedTitle: String {
        switch speed.phase {
        case .connecting: "Starting…"
        case .download, .upload: formatMbps(speed.liveSpeed) + " Mbps"
        case .done(let r): "↓ " + formatMbps(r.download)
        default: "Speed Test"
        }
    }

    private func closeThen(_ action: @escaping () -> Void) {
        viewModel.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: action)
    }
}

/// Every listening port, with the app behind it and a Stop button.
private struct PortsList: View {
    let onBack: () -> Void
    @EnvironmentObject private var ports: PortScanner
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(NotchIconButtonStyle(size: 22))
                Text("Listening Ports").font(.system(size: 13, weight: .semibold))
                if ports.loading { ProgressView().controlSize(.mini).tint(.white) }
                Spacer()
                Text("\(ports.listeners.count) open").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                Button("Refresh") { ports.refresh() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
            if ports.listeners.isEmpty {
                Text(ports.loading ? "Looking…" : "Nothing is listening")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(ports.listeners) { PortRow(listener: $0) }
                    }
                }
            }
        }
        .onAppear { ports.refresh() }
    }
}

private struct PortRow: View {
    let listener: PortScanner.Listener
    @EnvironmentObject private var ports: PortScanner
    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            Text(":" + String(listener.port))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 62, alignment: .leading)
            AppIcon(bundlePath: listener.app?.bundleURL?.path, size: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(listener.displayName).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text("PID " + String(listener.pid) + " · \(listener.isSystem ? "macOS · " : "")\(listener.isLocalOnly ? "this Mac only" : listener.address == "*" ? "all interfaces" : listener.address)")
                    .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if hovering || confirming {
                Button("Open") { ports.open(listener) }
                    .buttonStyle(NotchPillButtonStyle(height: 20))
                    .help("Open http://localhost:\(listener.port)")
                if !listener.isSystem {
                Button(confirming ? "Confirm" : "Stop") {
                    if confirming { confirming = false; ports.stop(listener) } else {
                        confirming = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirming = false }
                    }
                }
                .buttonStyle(NotchPillButtonStyle(primary: confirming, height: 20))
                .help("Quit \(listener.displayName)")
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A wide Control Center-style slider: drag anywhere on it to set the level.
private struct PillSlider: View {
    let icon: String
    let value: Float
    let onChange: (Float) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: max(geo.size.height, geo.size.width * CGFloat(min(1, max(0, value)))))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.7))
                    .frame(width: geo.size.height)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onChange(Float(min(1, max(0, g.location.x / max(geo.size.width, 1)))))
            })
        }
        .frame(height: 30)
    }
}

private struct ControlTile: View {
    let icon: String
    let title: String
    let on: Bool
    var onTint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ControlTileLabel(icon: icon, title: title, on: on, onTint: onTint)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

private struct ControlTileLabel: View {
    let icon: String
    let title: String
    let on: Bool
    let onTint: Color
    @State private var hovering = false

    var body: some View {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? (onTint == .white ? Color.black : .white) : .white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(on ? onTint : .white.opacity(hovering ? 0.16 : 0.1)))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Keep Awake: click to stop when on; otherwise pick how long (Amphetamine-style).
private struct KeepAwakeTile: View {
    @EnvironmentObject private var keepAwake: KeepAwake

    var body: some View {
        if keepAwake.isActive {
            ControlTile(icon: "cup.and.saucer.fill", title: keepAwake.remainingText.map { "Awake · \($0)" } ?? "Awake", on: true) {
                keepAwake.stop()
            }
            .help("Click to let your Mac sleep again")
        } else {
            ControlTile(icon: "cup.and.saucer.fill", title: "Keep Awake", on: false) {
                PopUpMenu.show(KeepAwake.Length.presets.map { length in
                    (length.label, length == .indefinitely ? "infinity" : "timer", { keepAwake.start(length) })
                },
                               title: "Keep awake for")
            }
            .help("Keep your Mac awake for…")
        }
    }
}

/// "3 updates available" under the sliders; opens the list.
private struct UpdatesCard: View {
    let action: () -> Void
    @EnvironmentObject private var updates: UpdateChecker
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: updates.updates.isEmpty ? "checkmark.seal.fill" : "arrow.down.app.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(updates.updates.isEmpty ? Color.green : Color.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5, weight: .semibold))
                    Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 0)
                if updates.checking { ProgressView().controlSize(.mini).tint(.white) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .notchSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), active: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var title: String {
        if updates.updates.isEmpty { return updates.lastChecked == nil ? "Software updates" : "Everything's up to date" }
        return updates.updates.count == 1 ? "1 update available" : "\(updates.updates.count) updates available"
    }

    private var subtitle: String {
        if updates.checking { return "Checking…" }
        guard let last = updates.lastChecked else { return "Homebrew and apps" }
        return "Checked " + last.formatted(.relative(presentation: .named))
    }
}

/// Every available update, with Update buttons.
private struct UpdatesList: View {
    let onBack: () -> Void
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(NotchIconButtonStyle(size: 22))
                Text("Updates").font(.system(size: 13, weight: .semibold))
                if updates.checking { ProgressView().controlSize(.mini).tint(.white) }
                Spacer()
                Button("Check Now") { updates.check() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .disabled(updates.checking)
                if updates.updates.contains(where: { $0.appURL == nil }) {
                    Button("Update All Homebrew") { updates.upgradeAllHomebrew() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            if let error = updates.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
            }
            if updates.updates.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(.green)
                    Text(updates.checking ? "Checking for updates…" : "Everything's up to date").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(updates.updates) { UpdateRow(update: $0) }
                    }
                }
            }
        }
    }
}

private struct UpdateRow: View {
    let update: UpdateChecker.Update
    @EnvironmentObject private var updates: UpdateChecker
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(update.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(update.installed) → \(update.available) · \(sourceLabel)")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if updates.upgrading.contains(update.name) {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Button(update.appURL == nil ? "Update" : "Open") { updates.upgrade(update) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(Capsule().fill(.white.opacity(hovering ? 0.2 : 0.12)))
                    .help(update.appURL == nil ? "brew upgrade \(update.name)" : "Opens the app so it can install its update")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        if let url = update.appURL ?? appForCask {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "shippingbox.fill").font(.system(size: 14)).foregroundStyle(Color(red: 0.98, green: 0.73, blue: 0.25))
        }
    }

    /// Casks are usually apps in /Applications; show their real icon when we can find it.
    private var appForCask: URL? {
        guard update.source == .cask else { return nil }
        let guess = update.name.replacingOccurrences(of: "-", with: " ")
        return AppIndex.shared.search(guess, limit: 1).first.flatMap { $0.score >= 85 ? $0.app.url : nil }
    }

    private var sourceLabel: String {
        switch update.source {
        case .formula: "Homebrew"
        case .cask: "Homebrew cask"
        case .sparkle: "App"
        }
    }
}

/// A plain NSMenu at the pointer, for choices that don't fit a SwiftUI Menu's look.
@MainActor
enum PopUpMenu {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    /// A choice: its title, its symbol (every item has one, as in the app's other menus), and what it does.
    typealias Item = (title: String, symbol: String, action: () -> Void)

    static func show(_ items: [Item], title: String? = nil) {
        show(sections: [items], title: title)
    }

    /// Groups of items with a separator between them.
    static func show(sections: [[Item]], title: String? = nil) {
        let menu = NSMenu()
        if let title {
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        var targets: [Target] = []
        for (i, items) in sections.filter({ !$0.isEmpty }).enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for (label, symbol, action) in items {
                let target = Target(action)
                targets.append(target)
                let item = NSMenuItem(title: label, action: #selector(Target.run), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                item.target = target
                menu.addItem(item)
            }
        }
        // popUp blocks until the menu closes, so the targets stay alive long enough.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(targets) {}
    }
}
