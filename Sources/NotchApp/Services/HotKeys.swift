import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// System-wide shortcuts that open the notch straight to a tab (Carbon hot keys: no
/// Accessibility permission needed). Pressing one again while that tab is showing closes it.
@MainActor
final class HotKeys: ObservableObject {
    static let shared = HotKeys()

    /// A key with its modifiers, as Carbon wants them, plus the key's name for display.
    /// An empty `key` means the shortcut is turned off.
    struct Combo: Codable, Equatable, Hashable {
        var keyCode: UInt32
        var modifiers: UInt32
        var key: String

        /// Turned off. (Not `none`: assigned to an optional, `.none` would mean nil, i.e. "back to the default".)
        static let off = Combo(keyCode: 0, modifiers: 0, key: "")
        var isNone: Bool { key.isEmpty }

        /// ⌃⌥⇧⌘ in the system's order, or ✦ for all four (Hyper).
        var modifierSymbols: String {
            if modifiers == Modifiers.hyper.carbon { return "✦" }
            var out = ""
            if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
            return out
        }

        var display: String { isNone ? "" : modifierSymbols + key }

        /// Reads a key press for the shortcut recorder. Needs ⌃, ⌥ or ⌘ (⇧ alone would eat
        /// ordinary typing), except for function keys.
        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var carbon: UInt32 = 0
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            let code = UInt32(event.keyCode)
            let function = Self.functionKeys[code]
            guard carbon & UInt32(controlKey | optionKey | cmdKey) != 0 || function != nil else { return nil }
            let name = function ?? Self.specialKeys[code]
                ?? event.characters(byApplyingModifiers: [])?.uppercased()
                ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || code == UInt32(kVK_Space) else { return nil }
            self.init(keyCode: code, modifiers: carbon, key: code == UInt32(kVK_Space) ? "Space" : name)
        }

        init(keyCode: UInt32, modifiers: UInt32, key: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.key = key
        }

        private static let functionKeys: [UInt32: String] = [
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
            UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
        ]
        private static let specialKeys: [UInt32: String] = [
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓", UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
            UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        ]
    }

    /// Actions whose shortcut couldn't be registered (usually another app has it).
    @Published private(set) var failed: Set<Action> = []
    /// While a shortcut is being recorded nothing is registered, so the keys reach the recorder.
    var suspended = false { didSet { if suspended != oldValue { register() } } }

    /// The shortcut an action uses now: its own if rebound, else the shared modifiers and its key.
    /// Nil when turned off.
    static func combo(for action: Action) -> Combo? {
        let s = AppSettings.shared
        if let own = s.hotKeyOverrides[action.rawValue] { return own.isNone ? nil : own }
        return action.onByDefault ? action.defaultCombo(s.hotKeyModifiers) : nil
    }

    enum Action: String, CaseIterable, Identifiable {
        // New actions go at the end: each one's position is its registered ID.
        case toggle, search, home, shelf, downloads, tasks, notes, timer, mixer, controls, camera, stats, tools, agents, clipboard, copyText, askScreen
        case windowLeft, windowRight, windowMaximize, windowCenter, windowNextDisplay, windowRestore
        case ramble
        case windowTop, windowBottom, windowPreviousDisplay
        case windowLeftThird, windowCenterThird, windowRightThird, windowLeftTwoThirds, windowRightTwoThirds
        case windowTopLeft, windowTopRight, windowBottomLeft, windowBottomRight

        /// Center and the thirds and quarters start off: their keys (Rectangle's) are tabs' with ⌃⌥.
        var onByDefault: Bool {
            ![.windowCenter, .windowLeftThird, .windowCenterThird, .windowRightThird, .windowLeftTwoThirds, .windowRightTwoThirds,
              .windowTopLeft, .windowTopRight, .windowBottomLeft, .windowBottomRight].contains(self)
        }

        var windowAction: WindowManager.Action? {
            switch self {
            case .windowLeft: .leftHalf
            case .windowRight: .rightHalf
            case .windowMaximize: .maximize
            case .windowCenter: .center
            case .windowNextDisplay: .nextDisplay
            case .windowPreviousDisplay: .previousDisplay
            case .windowTop: .topHalf
            case .windowBottom: .bottomHalf
            case .windowRestore: .restore
            case .windowLeftThird: .leftThird
            case .windowCenterThird: .centerThird
            case .windowRightThird: .rightThird
            case .windowLeftTwoThirds: .leftTwoThirds
            case .windowRightTwoThirds: .rightTwoThirds
            case .windowTopLeft: .topLeft
            case .windowTopRight: .topRight
            case .windowBottomLeft: .bottomLeft
            case .windowBottomRight: .bottomRight
            default: nil
            }
        }
        var id: String { rawValue }

        var key: String {
            switch self {
            case .toggle: "Space"
            case .search: "G"
            case .home: "M"
            case .shelf: "F"
            case .downloads: "D"
            case .tasks: "T"
            case .notes: "P"
            case .timer: "R"
            case .mixer: "V"
            case .controls: "C"
            case .camera: "W"
            case .stats: "I"
            case .tools: "O"
            case .agents: "A"
            case .clipboard: "B"
            case .copyText: "X"
            case .askScreen: "S"
            case .windowLeft: "←"
            case .windowRight: "→"
            case .windowMaximize: "↩"
            case .windowCenter: "C"
            case .windowNextDisplay: "→"
            case .windowPreviousDisplay: "←"
            case .windowTop: "↑"
            case .windowBottom: "↓"
            case .windowRestore: "⌫"
            case .ramble: "J"
            case .windowLeftThird: "D"
            case .windowCenterThird: "F"
            case .windowRightThird: "G"
            case .windowLeftTwoThirds: "E"
            case .windowRightTwoThirds: "T"
            case .windowTopLeft: "U"
            case .windowTopRight: "I"
            case .windowBottomLeft: "J"
            case .windowBottomRight: "K"
            }
        }

        var title: String {
            switch self {
            case .toggle: "Open or close the notch"
            case .search: "Search"
            case .home: "Now playing & calendar"
            case .shelf: "Shelf"
            case .downloads: "Downloads"
            case .tasks: "Tasks"
            case .notes: "Notes"
            case .timer: "Timer"
            case .mixer: "Sound mixer"
            case .controls: "Controls"
            case .camera: "Camera mirror"
            case .stats: "Stats"
            case .tools: "Tools"
            case .agents: "Agents"
            case .clipboard: "Clipboard history"
            case .copyText: "Copy text from the screen"
            case .askScreen: "Ask about what's on screen"
            case .windowLeft: "Window: left half"
            case .windowRight: "Window: right half"
            case .windowMaximize: "Window: maximize"
            case .windowCenter: "Window: center"
            case .windowNextDisplay: "Window: next display"
            case .windowRestore: "Window: restore"
            case .ramble: "Ramble: talk it out, get tasks back"
            case .windowTop: "Window: top half"
            case .windowBottom: "Window: bottom half"
            case .windowPreviousDisplay: "Window: previous display"
            case .windowLeftThird, .windowCenterThird, .windowRightThird, .windowLeftTwoThirds, .windowRightTwoThirds,
                 .windowTopLeft, .windowTopRight, .windowBottomLeft, .windowBottomRight:
                "Window: " + (windowAction?.title.lowercased() ?? "")
            }
        }

        /// The shared modifiers and its key. Window keys are ⌃⌥ whatever those are, as window tools
        /// have them (the display moves ⌃⌥⌘), so they're where the hands already go.
        func defaultCombo(_ modifiers: Modifiers) -> Combo {
            guard windowAction != nil else { return Combo(keyCode: keyCode, modifiers: modifiers.carbon, key: key) }
            let display = self == .windowNextDisplay || self == .windowPreviousDisplay
            return Combo(keyCode: keyCode, modifiers: UInt32(controlKey | optionKey | (display ? cmdKey : 0)), key: key)
        }

        var keyCode: UInt32 {
            switch self {
            case .toggle: UInt32(kVK_Space)
            case .search: UInt32(kVK_ANSI_G)
            case .home: UInt32(kVK_ANSI_M)
            case .shelf: UInt32(kVK_ANSI_F)
            case .downloads: UInt32(kVK_ANSI_D)
            case .tasks: UInt32(kVK_ANSI_T)
            case .notes: UInt32(kVK_ANSI_P)
            case .timer: UInt32(kVK_ANSI_R)
            case .mixer: UInt32(kVK_ANSI_V)
            case .controls: UInt32(kVK_ANSI_C)
            case .camera: UInt32(kVK_ANSI_W)
            case .stats: UInt32(kVK_ANSI_I)
            case .tools: UInt32(kVK_ANSI_O)
            case .agents: UInt32(kVK_ANSI_A)
            case .clipboard: UInt32(kVK_ANSI_B)
            case .copyText: UInt32(kVK_ANSI_X)
            case .askScreen: UInt32(kVK_ANSI_S)
            case .windowLeft: UInt32(kVK_LeftArrow)
            case .windowRight: UInt32(kVK_RightArrow)
            case .windowMaximize: UInt32(kVK_Return)
            case .windowCenter: UInt32(kVK_ANSI_C)
            case .windowNextDisplay: UInt32(kVK_RightArrow)
            case .windowPreviousDisplay: UInt32(kVK_LeftArrow)
            case .windowTop: UInt32(kVK_UpArrow)
            case .windowBottom: UInt32(kVK_DownArrow)
            case .windowRestore: UInt32(kVK_Delete)
            case .ramble: UInt32(kVK_ANSI_J)
            case .windowLeftThird: UInt32(kVK_ANSI_D)
            case .windowCenterThird: UInt32(kVK_ANSI_F)
            case .windowRightThird: UInt32(kVK_ANSI_G)
            case .windowLeftTwoThirds: UInt32(kVK_ANSI_E)
            case .windowRightTwoThirds: UInt32(kVK_ANSI_T)
            case .windowTopLeft: UInt32(kVK_ANSI_U)
            case .windowTopRight: UInt32(kVK_ANSI_I)
            case .windowBottomLeft: UInt32(kVK_ANSI_J)
            case .windowBottomRight: UInt32(kVK_ANSI_K)
            }
        }
    }

    enum Modifiers: String, CaseIterable, Identifiable {
        /// `hyper` is all four modifiers at once (⌃⌥⇧⌘), usually Caps Lock remapped by Karabiner or Raycast.
        case controlOption, optionCommand, controlCommand, hyper
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .controlOption: "⌃⌥"
            case .optionCommand: "⌥⌘"
            case .controlCommand: "⌃⌘"
            case .hyper: "✦"
            }
        }
        /// For the Settings picker, where "✦" alone wouldn't say what it is.
        var title: String { self == .hyper ? "✦ Hyper" : symbol }
        var carbon: UInt32 {
            switch self {
            case .controlOption: UInt32(controlKey | optionKey)
            case .optionCommand: UInt32(optionKey | cmdKey)
            case .controlCommand: UInt32(controlKey | cmdKey)
            case .hyper: UInt32(controlKey | optionKey | shiftKey | cmdKey)
            }
        }
    }

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        let s = AppSettings.shared
        s.$hotKeysEnabled.combineLatest(s.$hotKeyModifiers, s.$hotKeyOverrides)
            .sink { [weak self] _, _, _ in DispatchQueue.main.async { self?.register() } }
            .store(in: &cancellables)
        // Rectangle starting (at login it can come up after this), or quitting and letting go of its keys.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.publisher(for: name)
                .filter { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.rectangle }
                .sink { [weak self] note in
                    DispatchQueue.main.async {
                        if note.name == NSWorkspace.didTerminateApplicationNotification { self?.register() } else { self?.checkRectangle() }
                    }
                }
                .store(in: &cancellables)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkRectangle() }
    }

    // MARK: - Rectangle

    private static let rectangle = "com.knollsoft.Rectangle"
    private var askedAboutRectangle = false

    /// Rectangle running too, on the same window keys: both can register them, but only one app
    /// gets each press, so the other's quietly do nothing. Asked once a launch: quit Rectangle, or turn the
    /// window shortcuts here off. (Its keys are ⌃⌥ or ⌥⌘ unless changed; one of ours that
    /// couldn't register is taken for certain.)
    private func checkRectangle() {
        let windowKeys = Action.allCases.filter { $0.windowAction != nil && Self.combo(for: $0) != nil }
        let rectangleKeys = [UInt32(controlKey | optionKey), UInt32(optionKey | cmdKey)]
        let clash = windowKeys.contains { action in
            failed.contains(action) || rectangleKeys.contains { (Self.combo(for: action)?.modifiers ?? 0) & ~UInt32(cmdKey) == $0 & ~UInt32(cmdKey) }
        }
        guard !askedAboutRectangle, AppSettings.shared.hotKeysEnabled, clash,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.rectangle).first else { return }
        askedAboutRectangle = true
        DebugHooks.log("HotKeys: Rectangle is running on the same window keys; asking")
        let modifiers = Self.combo(for: .windowLeft)?.modifierSymbols ?? Self.combo(for: windowKeys[0])?.modifierSymbols ?? ""
        NotchPresenter.shared.offer(Prompt(icon: "rectangle.split.2x1", tint: .systemBlue, title: "Rectangle is running too",
                                           detail: "Both use \(modifiers) arrows for windows. Only one app gets each key.",
                                           actions: [.init(title: "Quit Rectangle", primary: true) { app.terminate() },
                                                     .init(title: "Keep Rectangle") {
                                                         for action in windowKeys { AppSettings.shared.hotKeyOverrides[action.rawValue] = .off }
                                                     }]))
    }

    private func register() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        let s = AppSettings.shared
        guard s.hotKeysEnabled, !suspended else { return }

        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let index = Int(id.id)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard Action.allCases.indices.contains(index) else { return }
                        HotKeys.shared.perform(Action.allCases[index])
                    }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }

        var failed: Set<Action> = []
        for (i, action) in Action.allCases.enumerated() {
            guard let combo = Self.combo(for: action) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4E4F5443), id: UInt32(i)) // 'NOTC'
            if RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            } else {
                failed.insert(action)
                DebugHooks.log("HotKeys: couldn't register \(combo.display) (taken by another app?)")
            }
        }
        if failed != self.failed { self.failed = failed }
        DebugHooks.log("HotKeys: registered \(refs.count) of \(Action.allCases.count)")
    }

    /// "Ask about this": captures the window in front, then opens search about it. Again while
    /// that's showing puts it away. (The shortcut, and the Glance.)
    static func askAboutScreen(_ vm: NotchViewModel, reason: OpenReason) {
        let assistant = AssistantStore.shared
        if vm.isOpen, vm.tab == .ask, assistant.context != nil {
            vm.close()
            return
        }
        // Capture first, while the window you mean is still the one in front.
        assistant.clear()
        assistant.captureContext()
        vm.mirror = false
        vm.overlay = nil
        vm.open(tab: .ask, reason: reason)
    }

    private func perform(_ action: Action) {
        guard let vm = NotchPresenter.shared.primary else { return }
        let defaults = UserDefaults.standard
        let target: NotchTab?
        switch action {
        case .toggle:
            vm.isOpen ? vm.close() : vm.open(reason: .keyboard)
            return
        case .camera:
            if vm.isOpen && vm.mirror { vm.close(); return }
            vm.open(reason: .keyboard)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { vm.mirror = true }
            return
        case .search: target = .ask
        case .home: target = .home
        case .shelf: defaults.set(ShelfPane.shelf.rawValue, forKey: "shelf.pane"); target = .shelf
        case .downloads: defaults.set(ShelfPane.downloads.rawValue, forKey: "shelf.pane"); target = .shelf
        case .tasks: defaults.set(TasksPane.tasks.rawValue, forKey: "tasks.pane"); target = .tasks
        case .notes: defaults.set(TasksPane.notes.rawValue, forKey: "tasks.pane"); target = .tasks
        case .timer: target = .timer
        case .mixer: target = .mixer
        case .controls: target = .controls
        case .stats: target = .stats
        case .tools: target = .tools
        case .agents: target = .agents
        case .clipboard: defaults.set(ShelfPane.clipboard.rawValue, forKey: "shelf.pane"); target = .shelf
        case .copyText:
            vm.close()
            SystemTweaks.shared.copyTextFromScreen()
            return
        case .askScreen:
            Self.askAboutScreen(vm, reason: .keyboard)
            return
        case .ramble:
            let ramble = RambleStore.shared
            if vm.isOpen, ramble.active { ramble.close(); vm.close() } else { ramble.open(vm) }
            return
        case .windowLeft, .windowRight, .windowTop, .windowBottom, .windowMaximize, .windowCenter,
             .windowNextDisplay, .windowPreviousDisplay, .windowRestore,
             .windowLeftThird, .windowCenterThird, .windowRightThird, .windowLeftTwoThirds, .windowRightTwoThirds,
             .windowTopLeft, .windowTopRight, .windowBottomLeft, .windowBottomRight:
            if let window = action.windowAction { WindowManager.apply(window) }
            return
        }
        guard let target, vm.tabs.contains(target) else { return }
        if vm.isOpen && vm.tab == target && !vm.mirror {
            vm.close()
        } else {
            vm.mirror = false
            vm.overlay = nil
            // Through `open` even when already open: a shortcut aimed at a hover-opened notch slides
            // to the tab and makes the notch stay put like one the shortcut opened.
            vm.open(tab: target, reason: .keyboard)
        }
    }
}
