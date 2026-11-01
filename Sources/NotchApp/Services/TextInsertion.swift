import AppKit

/// Puts text into the app you were in, as if typed: the notch closes, the text goes in with ⌘V,
/// and the clipboard is put back as it was. Without Accessibility it's copied, to paste yourself.
@MainActor
enum TextInsertion {
    static func insert(_ text: String) {
        let target = FrontmostTracker.shared.userApp
        NotchPresenter.shared.primary?.close()
        guard AXIsProcessTrusted(), let target else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ActivityCenter.shared.show(.notice(title: "Copied", detail: "Press ⌘V to paste", icon: "doc.on.clipboard"), for: 2)
            return
        }
        SelectionText.replace(with: text, in: .init(pid: target.processIdentifier, appName: target.localizedName), after: 0.2)
    }
}
