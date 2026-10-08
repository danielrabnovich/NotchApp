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
        MediaController.shared.start()
        AudioOutputManager.shared.start()
        BatteryMonitor.shared.start()
        HUDController.shared.start()
        ShelfStore.shared.load()
        TaskStore.shared.load()
        ScreenshotWatcher.shared.start()
        CalendarManager.shared.start()
        SystemMonitor.shared.start()
        AppIndex.shared.refreshIfNeeded()
        ScratchpadStore.shared.load()
        DownloadsStore.shared.start()
        TaildropService.shared.start()
        HotKeys.shared.start()
        UpdateChecker.shared.start()
        MouseUtilities.shared.start()
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
}
