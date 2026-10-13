import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchWindowController] = []
    private let mouse = MouseTracker()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        MediaController.shared.start()
        AudioOutputManager.shared.start()
        BatteryMonitor.shared.start()
        HUDController.shared.start()
        ShelfStore.shared.load()
        TaskStore.shared.load()
        ScreenshotWatcher.shared.start()
        CalendarManager.shared.start()
        SystemMonitor.shared.start()
        LiveActivities.shared.start()
        AudioSpectrum.shared.start()
        AppIndex.shared.refreshIfNeeded()
        ScratchpadStore.shared.load()
        DownloadsStore.shared.start()
        TaildropService.shared.start()
        HotKeys.shared.start()
        UpdateChecker.shared.start()
        MouseUtilities.shared.start()
        VisualSearch.shared.start()
        ImageIndex.shared.start()
        Cleaner.shared.start()
        ClipboardHistory.shared.start()
        NotificationMirror.shared.apply()
        DeviceBatteries.shared.start()
        PrivacyMonitor.shared.start()
        AgentMonitor.shared.start()
        FrontmostTracker.shared.start()
        AppActions.shared.start()
        ShortcutsApp.shared.refreshIfStale()
        HeatWatcher.shared.start()
        LeaveBy.shared.start()
        SoundAlerts.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Onboarding.showIfNeeded() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { CrashReports.checkAtLaunch() }
        AppUpdater.shared.start()
        MeetingMonitor.shared.start()
        ProgressCenter.shared.start()
        settings.$screenshotSearch.removeDuplicates().sink { on in
            DispatchQueue.main.async { ScreenshotText.shared.apply(on) }
        }.store(in: &cancellables)
        settings.$devServerAlerts.removeDuplicates().sink { on in
            DispatchQueue.main.async { DevServerWatcher.shared.apply(on) }
        }.store(in: &cancellables)
        settings.$connectionAlerts.removeDuplicates().sink { on in
            DispatchQueue.main.async { ConnectionWatcher.shared.apply(on) }
        }.store(in: &cancellables)
        settings.$agentsEnabled.combineLatest(settings.$agentAlerts, settings.$agentsKeepAwake).sink { _ in
            DispatchQueue.main.async { AgentMonitor.shared.update() }
        }.store(in: &cancellables)
        // The clipboard is watched for its history, and for links to clean.
        settings.$clipboardHistory.combineLatest(settings.$cleanLinks).sink { history, clean in
            DispatchQueue.main.async { ClipboardHistory.shared.apply(history || clean) }
        }.store(in: &cancellables)
        settings.$privacyAlerts.removeDuplicates().sink { _ in
            DispatchQueue.main.async { PrivacyMonitor.shared.update() }
        }.store(in: &cancellables)
        settings.$mixerEnabled.removeDuplicates().sink { enabled in
            DispatchQueue.main.async { AudioMixer.shared.setEnabled(enabled) }
        }.store(in: &cancellables)
        AssistantStore.shared.refreshStatus()
        BriefingService.shared.start()

        rebuildWindows()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildWindows() }
            .store(in: &cancellables)

        // @Published fires before the value is stored, so rebuild on the next runloop turn.
        settings.$displayMode.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildWindows() }
        }.store(in: &cancellables)
        settings.$showFakeNotch.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildWindows() }
        }.store(in: &cancellables)

        settings.$showMenuBarIcon
            .sink { [weak self] show in self?.updateStatusItem(show) }
            .store(in: &cancellables)

        mouse.start { [weak self] kind in
            self?.controllers.forEach { $0.handleMouse(kind) }
        }

        DebugHooks.install { [weak self] in self?.controllers ?? [] }
        // Build the search glow while nothing is happening, not in the first open's first frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SearchGlow.prewarm() }

        if !settings.hasLaunchedBefore {
            settings.hasLaunchedBefore = true
            SettingsWindowController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MediaController.shared.stop()
        AudioMixer.shared.stop()
        KeepAwake.shared.stop(announce: false)
    }

    // MARK: - Windows

    private func rebuildWindows() {
        controllers.forEach { $0.close() }
        controllers = targetScreens().map { NotchWindowController(screen: $0) }
        NotchPresenter.shared.primary = controllers.first?.viewModel
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        let notched = screens.filter(\.hasNotch)
        let allowFake = settings.showFakeNotch
        switch settings.displayMode {
        case .notched:
            if !notched.isEmpty { return notched }
            return allowFake ? Array(screens.prefix(1)) : []
        case .main:
            guard let primary = screens.first else { return [] }
            return (primary.hasNotch || allowFake) ? [primary] : []
        case .all:
            return screens.filter { $0.hasNotch || allowFake }
        }
    }

    // MARK: - Menu bar icon

    private func updateStatusItem(_ show: Bool) {
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchApp")
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit NotchApp", action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = menu
            statusItem = item
        } else if !show, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// ⌘, opens Settings. ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z reach text views through the main menu's Edit items. An app without a
    /// menu bar has none, so copying in the notch only worked from the right-click menu. This menu is
    /// never shown; it's there for the shortcuts.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // ⌘, opens Settings, like any Mac app (from the notch, or Settings itself).
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit NotchApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
