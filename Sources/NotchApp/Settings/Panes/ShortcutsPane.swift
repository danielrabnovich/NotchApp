import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutsPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var hotKeys = HotKeys.shared
    /// The field recording keys: "hot.<action>" or "clip.<key>".
    @State private var recording: String?
    @State private var filter = ""
    /// Said after a recording took keys from another action, which got this one's old keys.
    @State private var notice: String?

    private var query: String { filter.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ title: String, _ combo: HotKeys.Combo?) -> Bool {
        query.isEmpty || title.lowercased().contains(query)
            || (combo.map { $0.display.lowercased().contains(query) || $0.key.lowercased() == query } ?? false)
    }

    private func shown(_ group: ShortcutGroup) -> [HotKeys.Action] {
        group.actions.filter { matches($0.title, HotKeys.combo(for: $0)) }
    }

    private var shownShelfKeys: [ShelfKey] {
        s.shelfEnabled || s.clipboardHistory ? ShelfKey.allCases.filter { matches($0.title, $0.combo) } : []
    }

    var body: some View {
        SettingsPage(pane: .shortcuts) {
            Section {
                ToggleRow("Keyboard shortcuts", subtitle: "Press one again while its tab is showing to close the notch.", isOn: $s.hotKeysEnabled)
                if s.hotKeysEnabled {
                    Picker(selection: $s.hotKeyModifiers) {
                        ForEach(HotKeys.Modifiers.allCases) { Text($0.title).tag($0) }
                    } label: {
                        RowLabel(title: "Default modifier keys", subtitle: "For every shortcut you haven't changed, except window keys (always ⌃⌥, as in window tools). ⌥⌘ matches other notch apps but overrides some app shortcuts (⌥⌘D hides the Dock). "
                                 + "✦ Hyper is ⌃⌥⇧⌘ together: turn on Caps Lock is Hyper below to press it with one key.")
                    }
                    .pickerStyle(.segmented)
                }
                ToggleRow("Caps Lock is Hyper",
                          subtitle: "Hold Caps Lock for ⌃⌥⇧⌘ (✦), here and in every other app. Caps Lock no longer turns on capitals. "
                          + "Turn off the Hyper key in Tinycast, Raycast or Hyperkey if you use one there.",
                          isOn: $s.capsLockHyper)
                if s.capsLockHyper, !AXIsProcessTrusted() {
                    PermissionRow(title: "Accessibility", subtitle: "Needed to turn Caps Lock into ⌃⌥⇧⌘.", state: .unknown) {
                        HUDController.shared.requestAccessibility()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Filter by name or key", text: $filter)
                        .textFieldStyle(.plain)
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.borderless)
                    }
                }
                if (s.hotKeysEnabled ? ShortcutGroup.allCases.allSatisfy({ shown($0).isEmpty }) : true) && shownShelfKeys.isEmpty {
                    Text("No shortcuts match “\(filter)”")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            } header: {
                HStack {
                    Text("Shortcuts")
                    Spacer()
                    // Turning everything off, then picking the few you want, keeps stray presses harmless.
                    if s.hotKeysEnabled, HotKeys.Action.allCases.contains(where: { HotKeys.combo(for: $0) != nil }) {
                        Button("Turn Off All") {
                            s.hotKeyOverrides = Dictionary(uniqueKeysWithValues: HotKeys.Action.allCases.map { ($0.rawValue, HotKeys.Combo.off) })
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    if !s.hotKeyOverrides.isEmpty || !s.shelfKeyOverrides.isEmpty {
                        Button("Restore Defaults") {
                            s.hotKeyOverrides = [:]
                            s.shelfKeyOverrides = [:]
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            } footer: {
                FooterText(notice ?? "Click a shortcut and press new keys, or ⎋ to cancel. Click ✕ (or press ⌫ while recording) to turn one off. Keys another shortcut uses are swapped with it.")
            }
            if s.hotKeysEnabled {
                ForEach(ShortcutGroup.allCases) { group in
                    let actions = shown(group)
                    if !actions.isEmpty {
                        Section {
                            ForEach(actions) { row(for: $0, in: group) }
                        } header: {
                            Text(group.title)
                        } footer: {
                            if let note = group.note { FooterText(note) }
                        }
                    }
                }
            }
            if !shownShelfKeys.isEmpty { clipboardKeys }
        }
        .onDisappear { recording = nil }
        .onChange(of: notice) { _, text in
            guard let text else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if notice == text { notice = nil } }
        }
    }

    private func row(for action: HotKeys.Action, in group: ShortcutGroup) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let problem = problem(for: action) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help(problem)
                }
                ShortcutRecorder(action: action, recording: $recording) { notice = $0 }
                Button {
                    s.hotKeyOverrides[action.rawValue] = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(action.onByDefault ? "Reset to \(action.defaultCombo(s.hotKeyModifiers).display)" : "Reset (turns it off)")
                .opacity(s.hotKeyOverrides[action.rawValue] == nil ? 0 : 1)
                .disabled(s.hotKeyOverrides[action.rawValue] == nil)
            }
        } label: {
            Text(group.label(for: action))
                .foregroundStyle(HotKeys.combo(for: action) == nil ? .secondary : .primary)
        }
        .contextMenu {
            MenuItem("Record New Shortcut", "record.circle") { recording = "hot." + action.rawValue }
            MenuItem("Turn Off", "xmark.circle") { s.hotKeyOverrides[action.rawValue] = HotKeys.Combo.off }
                .disabled(HotKeys.combo(for: action) == nil)
            MenuItem("Restore Default (\(action.onByDefault ? action.defaultCombo(s.hotKeyModifiers).display : "Off"))", "arrow.uturn.backward") {
                s.hotKeyOverrides[action.rawValue] = nil
            }
            .disabled(s.hotKeyOverrides[action.rawValue] == nil)
        }
    }

    /// Keys inside the Shelf tab (Shelf, Downloads, Clipboard), while the notch has the keyboard.
    private var clipboardKeys: some View {
        Section {
            ForEach(shownShelfKeys) { key in
                LabeledContent {
                    HStack(spacing: 6) {
                        if let combo = key.combo, let global = HotKeys.Action.allCases.first(where: { HotKeys.combo(for: $0) == combo }) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help("\(combo.display) is also the shortcut for “\(global.title)”, which takes it first.")
                        }
                        ShelfKeyRecorder(key: key, recording: $recording) { notice = $0 }
                        Button {
                            s.shelfKeyOverrides[key.rawValue] = nil
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Reset to \(key.defaultCombo.display)")
                        .opacity(s.shelfKeyOverrides[key.rawValue] == nil ? 0 : 1)
                        .disabled(s.shelfKeyOverrides[key.rawValue] == nil)
                    }
                } label: {
                    Text(key.title)
                        .foregroundStyle(key.combo == nil ? .secondary : .primary)
                }
                .contextMenu {
                    MenuItem("Record New Shortcut", "record.circle") { recording = "clip." + key.rawValue }
                    MenuItem("Turn Off", "xmark.circle") { s.shelfKeyOverrides[key.rawValue] = HotKeys.Combo.off }
                        .disabled(key.combo == nil)
                    MenuItem("Restore Default (\(key.defaultCombo.display))", "arrow.uturn.backward") { s.shelfKeyOverrides[key.rawValue] = nil }
                        .disabled(s.shelfKeyOverrides[key.rawValue] == nil)
                }
            }
        } header: {
            Text("In the Shelf Tab")
        } footer: {
            FooterText("For the Shelf, Downloads and Clipboard while the notch has the keyboard: ← → move (⇧ picks several), Space is Quick Look "
                       + "for files, and typing searches the clipboard. These act on what's highlighted or picked; hold quick paste's modifiers to see the numbers.")
        }
    }

    /// Why a shortcut won't work, if it won't: another action has it, or another app does.
    private func problem(for action: HotKeys.Action) -> String? {
        guard let combo = HotKeys.combo(for: action) else { return nil }
        if let other = HotKeys.Action.allCases.first(where: { $0 != action && HotKeys.combo(for: $0) == combo }) {
            return "\(combo.display) is also used for “\(other.title)”."
        }
        if hotKeys.failed.contains(action) { return "\(combo.display) is in use by another app or macOS." }
        return nil
    }
}

/// How the Shortcuts pane sorts the global shortcuts: by what they do.
private enum ShortcutGroup: CaseIterable, Identifiable {
    case notch, tabs, actions, windows

    var id: Self { self }

    var title: String {
        switch self {
        case .notch: "Opening the Notch"
        case .tabs: "Go to a Tab"
        case .actions: "Actions"
        case .windows: "Windows"
        }
    }

    var note: String? {
        switch self {
        case .tabs: "Opens the notch on that tab; press it again to close."
        case .windows: "Moves the window in front. Press left or right again to send it on to the display that way, or, with none there, to ⅔ and then ⅓ of the screen. Thirds and quarters start off: record a key to use one."
        default: nil
        }
    }

    /// In the order they're listed (tabs roughly as the tab bar has them).
    var actions: [HotKeys.Action] {
        switch self {
        case .notch: [.toggle, .search, .chat]
        case .tabs: [.home, .shelf, .downloads, .clipboard, .tasks, .notes, .timer, .mixer, .controls, .camera, .stats, .tools, .agents]
        // Plus any new action not given a group yet, so it can't go missing from the pane.
        case .actions: [.copyText, .askScreen, .askArea, .ramble] + HotKeys.Action.allCases.filter { a in !Self.listed.contains(a) }
        case .windows: [.windowLeft, .windowRight, .windowTop, .windowBottom, .windowMaximize, .windowCenter,
                         .windowPreviousDisplay, .windowNextDisplay, .windowRestore,
                         .windowLeftThird, .windowCenterThird, .windowRightThird, .windowLeftTwoThirds, .windowRightTwoThirds,
                         .windowTopLeft, .windowTopRight, .windowBottomLeft, .windowBottomRight]
        }
    }

    private static let listed = Set<HotKeys.Action>([.copyText, .askScreen, .askArea, .ramble] + notch.actions + tabs.actions + windows.actions)

    /// The action's name, without what the group heading already says.
    func label(for action: HotKeys.Action) -> String {
        guard self == .windows, action.title.hasPrefix("Window: ") else { return action.title }
        let rest = action.title.dropFirst("Window: ".count)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }
}

/// A global shortcut's field: records keys for a `HotKeys.Action`, swapping with whichever
/// other action had them.
private struct ShortcutRecorder: View {
    let action: HotKeys.Action
    @Binding var recording: String?
    /// Called with a message when recording swapped keys with another action.
    var swapped: (String) -> Void = { _ in }
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        KeyRecorder(title: action.title, combo: HotKeys.combo(for: action),
                    isRecording: Binding(get: { recording == "hot." + action.rawValue },
                                         set: { recording = $0 ? "hot." + action.rawValue : nil }),
                    read: { HotKeys.Combo(event: $0) }, set: set, taken: swapped)
    }

    private func set(_ combo: HotKeys.Combo) {
        let old = HotKeys.combo(for: action)
        var overrides = s.hotKeyOverrides
        // Keys another action has: it takes this one's old keys (or none), so nothing clashes.
        if !combo.isNone, combo != old,
           let other = HotKeys.Action.allCases.first(where: { $0 != action && HotKeys.combo(for: $0) == combo }) {
            let given = old ?? HotKeys.Combo.off
            overrides[other.rawValue] = given == other.defaultCombo(s.hotKeyModifiers) ? nil : given
            swapped(old.map { "Swapped with “\(other.title)”, which is now \($0.display)." } ?? "“\(other.title)” had \(combo.display), so it's now off.")
        }
        // Back to the default? Then it's not an override any more, and follows the default modifiers.
        overrides[action.rawValue] = combo == action.defaultCombo(s.hotKeyModifiers) ? nil : combo
        s.hotKeyOverrides = overrides
    }
}

/// A Clipboard pane key's field, swapping with whichever other Clipboard key had them.
private struct ShelfKeyRecorder: View {
    let key: ShelfKey
    @Binding var recording: String?
    var swapped: (String) -> Void = { _ in }
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        KeyRecorder(title: key.title, combo: key.combo,
                    isRecording: Binding(get: { recording == "clip." + key.rawValue },
                                         set: { recording = $0 ? "clip." + key.rawValue : nil }),
                    read: key.record, set: set, taken: swapped)
    }

    private func set(_ combo: HotKeys.Combo) {
        let old = key.combo
        var overrides = s.shelfKeyOverrides
        if !combo.isNone, combo != old, let other = ShelfKey.allCases.first(where: { $0 != key && $0.combo == combo }) {
            let given = old ?? HotKeys.Combo.off
            overrides[other.rawValue] = given == other.defaultCombo ? nil : given
            swapped(old.map { "Swapped with “\(other.title)”, which is now \($0.display)." } ?? "“\(other.title)” had \(combo.display), so it's now off.")
        }
        overrides[key.rawValue] = combo == key.defaultCombo ? nil : combo
        s.shelfKeyOverrides = overrides
    }
}

/// A shortcut field: shows the keys, and records new ones when clicked (like System Settings' fields).
private struct KeyRecorder: View {
    /// What the keys do, for VoiceOver.
    let title: String
    let combo: HotKeys.Combo?
    @Binding var isRecording: Bool
    /// The keys a press makes, or nil if they can't be used (a beep).
    let read: (NSEvent) -> HotKeys.Combo?
    /// Takes new keys, or `.off`.
    let set: (HotKeys.Combo) -> Void
    /// Says why keys another app holds were recorded but won't work.
    var taken: (String) -> Void = { _ in }
    @State private var monitor: Any?
    /// Sees key presses before any app does, so keys another app has taken as its shortcut (which
    /// never reach this window) still get recorded, with a word on why they won't work.
    @State private var listener: Int?
    @State private var lastLocalKey = Date.distantPast
    @State private var held: String = ""
    @State private var hovering = false
    /// Fields recording right now: global shortcuts stay unregistered until none is.
    private static var active = 0

    var body: some View {
        // The field and its turn-off ✕ are sibling buttons (a button nested in another never gets
        // the click). Plain tap gestures don't work here: Form rows don't pass them clicks.
        ZStack {
            Button {
                isRecording.toggle()
            } label: {
                Group {
                    if isRecording {
                        Text(held.isEmpty ? "Type Shortcut" : held)
                            .foregroundStyle(held.isEmpty ? .secondary : .primary)
                    } else if let combo {
                        Text(combo.display)
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 22)
                .frame(width: 124, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hovering ? 0.09 : 0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isRecording ? 1.5 : 0.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shortcut for \(title)")
            HStack {
                Spacer()
                if hovering, !isRecording, combo != nil {
                    Button {
                        set(.off)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Turn off this shortcut")
                    .accessibilityLabel("Turn off shortcut for \(title)")
                    .transition(.opacity)
                }
            }
            .padding(.trailing, 2)
        }
        .frame(width: 124, height: 22)

        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(isRecording ? "Press keys, ⌫ to turn off, ⎋ to cancel" : "Click to change")
        .onChange(of: isRecording) { _, on in on ? start() : stop() }
        .onDisappear { stop() }
    }

    private func start() {
        guard monitor == nil else { return }
        held = ""
        Self.active += 1
        HotKeys.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            switch event.type {
            case .leftMouseDown:
                // Clicking anywhere else ends recording; the click still goes through.
                DispatchQueue.main.async { if isRecording { isRecording = false } }
                return event
            case .flagsChanged:
                held = HotKeys.Combo(keyCode: 0, modifiers: ShelfKey.carbon(event.modifierFlags), key: "x").modifierSymbols
                return nil
            default:
                let bare = event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
                if event.keyCode == UInt16(kVK_Escape), bare {
                    isRecording = false
                } else if [UInt16(kVK_Delete), UInt16(kVK_ForwardDelete)].contains(event.keyCode), bare, read(event) == nil {
                    set(.off)
                    isRecording = false
                } else if let combo = read(event) {
                    set(combo)
                    isRecording = false
                } else {
                    NSSound.beep()
                }
                lastLocalKey = Date()
                return nil
            }
        }
        listener = KeyListener.start { event in
            let seen = Date()
            // The window gets its own presses a moment later; one that never arrives went to another app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                // Only while Settings is in front: with another app active, its keys are just being typed there.
                guard isRecording, NSApp.isActive, lastLocalKey < seen, let combo = read(event) else { return }
                set(combo)
                isRecording = false
                let owner = HotKeyOwners.owner(of: combo).map { " (\($0))" } ?? ""
                taken("\(combo.display) is taken by another app\(owner), so it never reaches NotchApp. Free it there and it'll work.")
            }
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        if let listener { KeyListener.stop(listener) }
        listener = nil
        held = ""
        Self.active -= 1
        if Self.active == 0 { HotKeys.shared.suspended = false }
    }
}

/// A listen-only tap on key presses for the shortcut recorder (needs Accessibility; without it,
/// there's no tap and keys another app holds just don't record). One field records at a time.
@MainActor
private enum KeyListener {
    nonisolated(unsafe) private static var handler: ((NSEvent) -> Void)?
    private static var tap: (port: CFMachPort, source: CFRunLoopSource)?
    private static var generation = 0

    /// Returns a token for `stop`, so a field that stops late can't end the next one's listening.
    static func start(_ handler: @escaping (NSEvent) -> Void) -> Int {
        stop(generation)
        generation += 1
        guard AXIsProcessTrusted(),
              let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
                                           callback: { _, type, event, _ in
                                               if type == .keyDown, let ns = NSEvent(cgEvent: event) { KeyListener.handler?(ns) }
                                               return Unmanaged.passUnretained(event)
                                           }, userInfo: nil),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return generation }
        // On the main run loop, so the handler runs on the main thread.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        Self.handler = handler
        tap = (port, source)
        return generation
    }

    static func stop(_ token: Int) {
        guard token == generation, let tap else { return }
        handler = nil
        CGEvent.tapEnable(tap: tap.port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.source, .commonModes)
        CFMachPortInvalidate(tap.port)
        Self.tap = nil
    }
}
