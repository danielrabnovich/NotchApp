import AppKit
import Carbon.HIToolbox

/// Keys for the Clipboard pane while the notch has the keyboard, like Raycast's clipboard history:
/// ← → (or ↑ ↓) move a highlight through the clips, ⇧ with them picks several, typing searches,
/// and these act on what's highlighted (or picked). Each can be rebound in Settings → Shortcuts.
enum ClipboardKey: String, CaseIterable, Identifiable {
    case paste, copy, delete, pin, quickPaste

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: "Paste into the app you were in"
        case .copy: "Copy"
        case .delete: "Remove from the history"
        case .pin: "Pin or unpin"
        case .quickPaste: "Paste the 1st to 9th clip"
        }
    }

    /// What quick paste shows for its key: it's one modifier combination over the digits.
    static let digits = "1–9"

    var defaultCombo: HotKeys.Combo {
        switch self {
        case .paste: HotKeys.Combo(keyCode: UInt32(kVK_Return), modifiers: 0, key: "↩")
        case .copy: HotKeys.Combo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey), key: "C")
        case .delete: HotKeys.Combo(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(controlKey), key: "X")
        case .pin: HotKeys.Combo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(shiftKey | cmdKey), key: "P")
        case .quickPaste: HotKeys.Combo(keyCode: 0, modifiers: UInt32(cmdKey), key: Self.digits)
        }
    }

    /// The keys it uses now: its own if rebound, else its default. Nil when turned off.
    @MainActor var combo: HotKeys.Combo? {
        guard let own = AppSettings.shared.clipboardKeyOverrides[rawValue] else { return defaultCombo }
        return own.isNone ? nil : own
    }

    /// The action a key press is, if it's one of these, with the digit for quick paste.
    @MainActor static func match(_ event: NSEvent) -> (key: ClipboardKey, digit: Int?)? {
        let mods = carbon(event.modifierFlags)
        for key in allCases {
            guard let combo = key.combo, combo.modifiers == mods else { continue }
            if key == .quickPaste {
                if let n = digit(event) { return (key, n) }
            } else if UInt32(event.keyCode) == combo.keyCode
                        || (combo.keyCode == UInt32(kVK_Return) && event.keyCode == UInt16(kVK_ANSI_KeypadEnter)) {
                return (key, nil)
            }
        }
        return nil
    }

    /// Reads a key press for the shortcut recorder. Plain letters would stop typing reaching the
    /// search, and plain arrows move the highlight, so those need ⌃, ⌥ or ⌘; ↩, ⌦ and the function
    /// keys work alone. Quick paste takes any digit and keeps only its modifiers.
    func record(_ event: NSEvent) -> HotKeys.Combo? {
        let mods = Self.carbon(event.modifierFlags)
        let strong = mods & UInt32(controlKey | optionKey | cmdKey) != 0
        if self == .quickPaste {
            guard strong, Self.digit(event) != nil else { return nil }
            return HotKeys.Combo(keyCode: 0, modifiers: mods, key: Self.digits)
        }
        if strong { return HotKeys.Combo(event: event) }
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return HotKeys.Combo(keyCode: UInt32(kVK_Return), modifiers: mods, key: "↩")
        case kVK_ForwardDelete: return HotKeys.Combo(keyCode: UInt32(kVK_ForwardDelete), modifiers: mods, key: "⌦")
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow: return nil
        default: return HotKeys.Combo(event: event) // the function keys
        }
    }

    /// ⌃⌥⇧⌘ as Carbon has them, the way `HotKeys.Combo` stores them.
    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if flags.contains(.control) { out |= UInt32(controlKey) }
        if flags.contains(.option) { out |= UInt32(optionKey) }
        if flags.contains(.shift) { out |= UInt32(shiftKey) }
        if flags.contains(.command) { out |= UInt32(cmdKey) }
        return out
    }

    /// 1 to 9 from the number row or the keypad, whatever the modifiers turn the character into.
    static func digit(_ event: NSEvent) -> Int? {
        let row = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let pad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                   kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        let code = Int(event.keyCode)
        if let i = row.firstIndex(of: code) ?? pad.firstIndex(of: code) { return i + 1 }
        return nil
    }
}
