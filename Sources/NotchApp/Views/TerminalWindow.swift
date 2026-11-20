import AppKit
import SwiftTerm
import SwiftUI

/// A terminal that drops from the notch on ⌃⌥` and goes back up on the same keys: your own login
/// shell in a real pseudo-terminal (SwiftTerm), on the notch's glass. It opens where you're
/// working: the Finder window in front, else the folder of the coding agent that last did
/// something, else home. Hiding it keeps the shell running, so it's where you left it; `exit`
/// closes it for good, and the next one starts fresh.
@MainActor
final class TerminalWindow: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalWindow()

    private var panel: TerminalPanel?
    private var terminal: LocalProcessTerminalView?

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow { return hide() }
        show()
    }

    func show() {
        NotchPresenter.shared.primary?.close()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { place(panel) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let terminal { panel.makeFirstResponder(terminal) }
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> TerminalPanel {
        let panel = TerminalPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 380))
        panel.onClose = { [weak self] in self?.hide() }
        let glass = NSHostingView(rootView: TerminalGlass().notchEnvironment())
        glass.sizingOptions = []
        let container = NSView(frame: panel.contentLayoutRect)
        container.autoresizingMask = [.width, .height]
        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        let term = LocalProcessTerminalView(frame: container.bounds.insetBy(dx: 14, dy: 12))
        term.autoresizingMask = [.width, .height]
        term.processDelegate = self
        term.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        term.nativeBackgroundColor = .clear
        term.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
        term.caretColor = .white
        term.wantsLayer = true
        term.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(term)
        panel.contentView = container
        terminal = term
        start(term)
        return panel
    }

    private func start(_ term: LocalProcessTerminalView) {
        let shell = Self.loginShell
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "NotchApp"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // A leading dash makes it a login shell, as Terminal starts one.
        term.startProcess(executable: shell, args: [], environment: env.map { "\($0.key)=\($0.value)" },
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: Self.startingFolder())
    }

    private static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    /// Where you're working: Finder's front window if Finder is in front, else the folder of the
    /// agent session that changed last, else home.
    private static func startingFolder() -> String {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder",
           let path = finderFolder() { return path }
        if let dir = AgentMonitor.shared.sessions.max(by: { $0.updated < $1.updated })?.directory,
           FileManager.default.fileExists(atPath: dir) { return dir }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func finderFolder() -> String? {
        let script = NSAppleScript(source: "tell application \"Finder\" to if (count of Finder windows) > 0 then return POSIX path of (target of front Finder window as alias)")
        var error: NSDictionary?
        let path = script?.executeAndReturnError(&error).stringValue
        return path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    /// Centred under the notch, on the screen that has it.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, 24) - 8
        var frame = panel.frame
        frame.origin = NSPoint(x: screen.frame.midX - frame.width / 2, y: top - frame.height)
        panel.setFrame(frame, display: false)
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// `exit`: the window goes, and the next ⌃⌥` starts a new shell.
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let me = TerminalWindow.shared
                me.panel?.orderOut(nil)
                me.panel = nil
                me.terminal = nil
            }
        }
    }
}

/// The notch's glass behind the terminal, dark enough for text over anything.
private struct TerminalGlass: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TrayGlass(look: DynamicGlass.Look(amount: settings.glassAmount), glass: settings.usesGlass, radius: 22, minShade: 0.95)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .circular))
            .background(settings.usesGlass ? Color.clear : Color.black.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .circular))
    }
}

/// Borderless, so the glass is the whole window; takes the keyboard, moves by its background,
/// resizes from its edges. Esc belongs to the shell (vim, less), so ⌘W hides it.
private final class TerminalPanel: NSPanel {
    var onClose: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: 420, height: 200)
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "w" {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
