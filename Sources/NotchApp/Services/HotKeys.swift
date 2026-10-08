import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// System-wide shortcuts that open the notch straight to a tab (Carbon hot keys: no
/// Accessibility permission needed). Pressing one again while that tab is showing closes it.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    enum Action: String, CaseIterable, Identifiable {
        case toggle, search, home, shelf, downloads, tasks, notes, timer, mixer, controls, camera, stats
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
            }
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
        s.$hotKeysEnabled.combineLatest(s.$hotKeyModifiers)
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.register() } }
            .store(in: &cancellables)
    }

    private func register() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        let s = AppSettings.shared
        guard s.hotKeysEnabled else { return }

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

        let modifiers = s.hotKeyModifiers.carbon
        for (i, action) in Action.allCases.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4E4F5443), id: UInt32(i)) // 'NOTC'
            if RegisterEventHotKey(action.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            } else {
                DebugHooks.log("HotKeys: couldn't register \(s.hotKeyModifiers.symbol)\(action.key) (taken by another app?)")
            }
        }
        DebugHooks.log("HotKeys: registered \(refs.count) of \(Action.allCases.count)")
    }

    private func perform(_ action: Action) {
        guard let vm = NotchPresenter.shared.primary else { return }
        let defaults = UserDefaults.standard
        let target: NotchTab?
        switch action {
        case .toggle:
            vm.isOpen ? vm.close() : vm.open()
            return
        case .camera:
            if vm.isOpen && vm.mirror { vm.close(); return }
            vm.open()
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
        }
        guard let target, vm.tabs.contains(target) else { return }
        if vm.isOpen && vm.tab == target && !vm.mirror {
            vm.close()
        } else {
            vm.mirror = false
            vm.overlay = nil
            if vm.isOpen { vm.select(target) } else { vm.open(tab: target) }
        }
    }
}
