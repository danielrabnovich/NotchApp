import AppKit
import Combine
import SwiftUI
import Translation

/// Select text in any app (a drag, a double or triple click) and a small bar comes up just above
/// where the pointer let go: Copy, Search in the notch, and the first four of your own AI Commands
/// (their order in Settings is the bar's). It never takes the app's focus, so a command that
/// replaces text puts it straight back in place. It goes at the next click, key or scroll, or after
/// a few seconds left alone.
@MainActor
final class SelectionPill {
    static let shared = SelectionPill()

    private var monitors: [Any] = []
    private var downAt: (point: NSPoint, time: TimeInterval)?
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var pending: DispatchWorkItem?
    private var hovering = false
    /// The translation popover is up: the bar stays until it closes.
    private var holding = false

    func start() {
        AppSettings.shared.$selectionPill.removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async { on ? self?.install() : self?.uninstall() }
        }.store(in: &cancellables)
    }
    private var cancellables = Set<AnyCancellable>()

    private func install() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { event in
            MainActor.assumeIsolated { SelectionPill.shared.mouse(event) }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { SelectionPill.shared.hide() }
        }) { monitors.append(m) }
    }

    private func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hide()
    }

    private func mouse(_ event: NSEvent) {
        let at = NSEvent.mouseLocation
        if event.type == .leftMouseDown {
            pending?.cancel()
            hide()
            downAt = (at, event.timestamp)
            return
        }
        // A drag across text, or a double or triple click on a word or line.
        guard let down = downAt else { return }
        downAt = nil
        let dragged = hypot(at.x - down.point.x, at.y - down.point.y) > 6
        guard dragged || event.clickCount >= 2 else { return }
        // The app settles its selection first; Accessibility reads it after.
        let work = DispatchWorkItem { MainActor.assumeIsolated { SelectionPill.shared.offer(at: at) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func offer(at point: NSPoint) {
        guard let (text, source) = SelectionText.read() else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A stray letter, or a whole page selected with ⌘A by drag: neither wants a bar.
        guard trimmed.count >= 2, trimmed.count < 20_000 else { return }
        show(text, from: source, at: point)
    }

    private func show(_ text: String, from source: SelectionText.Source, at point: NSPoint) {
        hide()
        let commands = Array(AICommandStore.shared.commands.prefix(4))
        let view = PillView(commands: commands, text: text, source: source, done: { [weak self] in self?.hide() },
                            hover: { [weak self] on in self?.hovering = on; if !on { self?.hideLater() } },
                            hold: { [weak self] on in self?.holding = on; if !on { self?.hideLater() } })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = host
        // Just above where the pointer let go, kept on its screen.
        let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? .zero
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y + 14)
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)
        if origin.y + size.height > screen.maxY { origin.y = point.y - size.height - 18 }
        p.setFrameOrigin(origin)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p
        hideLater()
    }

    private func hideLater() {
        hideWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { if !SelectionPill.shared.hovering, !SelectionPill.shared.holding { SelectionPill.shared.hide() } } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hovering = false
        holding = false
        guard let p = panel else { return }
        panel = nil
        p.orderOut(nil)
    }
}

private struct PillView: View {
    let commands: [AICommand]
    let text: String
    let source: SelectionText.Source
    let done: () -> Void
    let hover: (Bool) -> Void
    let hold: (Bool) -> Void
    @State private var copied = false
    @State private var translating = false

    var body: some View {
        HStack(spacing: 2) {
            button(copied ? "checkmark" : "doc.on.doc", "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
            }
            button("magnifyingglass", "Search in the notch") {
                done()
                AssistantStore.shared.run(text)
                NotchPresenter.shared.primary?.open(tab: .ask, takeKeyboard: false, reason: .system)
            }
            if #available(macOS 15, *) {
                // Apple's own translator, on this Mac: it finds the language, and Replace puts the
                // translation back where the text was.
                button("translate", "Translate") { translating = true }
                    .translationPresentation(isPresented: $translating, text: text, arrowEdge: .bottom) { translated in
                        done()
                        SelectionText.replace(with: translated, in: source, after: 0.2)
                    }
                    .onChange(of: translating) { _, on in hold(on) }
            }
            if !commands.isEmpty {
                Divider().frame(height: 16).overlay(Color.white.opacity(0.2))
            }
            ForEach(commands) { command in
                button(command.icon, command.name) {
                    done()
                    AICommandRunner.run(command)
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .onHover(perform: hover)
    }

    private func button(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PillButtonStyle())
        .help(help)
    }
}

private struct PillButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.22 : hovering ? 0.12 : 0)))
            .onHover { hovering = $0 }
    }
}
