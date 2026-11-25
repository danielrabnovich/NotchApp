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
        let pointer = PillPointer()
        let ask = AskSession(text: text, source: source)
        session = ask
        let view = PillView(commands: commands, text: text, source: source, pointer: pointer, ask: ask,
                            done: { [weak self] in self?.hide() },
                            hold: { [weak self] on in self?.holding = on; if !on { self?.hideLater() } },
                            asking: { [weak self] in self?.beginAsking() },
                            resized: { [weak self] size in self?.fit(size) })
            .coordinateSpace(name: PillPointer.space)
        let host = PillHostingView(rootView: view, pointer: pointer) { [weak self] on in
            self?.hovering = on
            if !on { self?.hideLater() }
        }
        let size = host.fittingSize
        // Measured once; from here the pill's own size reports move the panel (`fit`).
        host.sizingOptions = []
        stopHost = { [weak host] in host?.stop() }
        let p = PillPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.becomesKeyOnlyIfNeeded = true
        // Hover has to work while another app is in front: the pill never takes the focus.
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = host
        // Just above where the pointer let go, kept on its screen.
        let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? .zero
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y + 14)
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)
        below = origin.y + size.height > screen.maxY
        if below { origin.y = point.y - size.height - 18 }
        p.setFrameOrigin(origin)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p
        hideLater()
    }

    /// The pill went under the text (no room above it): it grows downwards, else upwards, so it
    /// never slides over what was selected.
    private var below = false
    private var stopHost: (() -> Void)?
    private var session: AskSession?

    /// Debug: the pill for the frontmost app's selection, at the pointer; then Ask in it.
    func debugOffer(pid: pid_t? = nil) {
        guard let pid else { return offer(at: NSEvent.mouseLocation) }
        // A given app's selection, wherever it is (a test window behind a full-screen app).
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?, selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused,
              AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        show(text, from: SelectionText.Source(pid: pid, appName: NSRunningApplication(processIdentifier: pid)?.localizedName),
             at: NSPoint(x: screen.midX, y: screen.midY))
    }
    func debugSnapshot(to url: URL) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    func debugAsk(_ question: String) {
        guard let session else { return }
        beginAsking()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { session.open = true }
        if !question.isEmpty { session.ask(question) }
    }

    /// Ask about this: the pill takes the keyboard for its field (still without bringing NotchApp
    /// forward, so the app keeps its selection to replace) and stays until it's done with.
    private func beginAsking() {
        holding = true
        hideWork?.cancel()
        panel?.makeKey()
    }

    /// Follows the pill's size as it opens into the Ask card and the answer comes in, keeping
    /// the edge nearest the text where it was and the whole thing on screen.
    private func fit(_ size: CGSize) {
        guard let p = panel, size.width > 0, size.height > 0, p.frame.size != size else { return }
        var frame = p.frame
        let screen = p.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let midX = frame.midX
        if below { frame.origin.y = frame.maxY - size.height }
        frame.size = size
        frame.origin.x = min(max(midX - size.width / 2, screen.minX + 6), screen.maxX - size.width - 6)
        frame.origin.y = min(max(frame.origin.y, screen.minY + 6), screen.maxY - size.height - 6)
        p.setFrame(frame, display: true)
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
        stopHost?()
        stopHost = nil
        p.orderOut(nil)
    }
}

/// Borderless, so it needs telling it may take the keyboard (for Ask's field); Esc puts it away.
private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { SelectionPill.shared.hide() }
}

/// Where the pointer is over the pill, from AppKit. SwiftUI's own hover only follows the pointer
/// in the app in front, and the pill sits over another app, so highlights lagged or never came.
@MainActor
final class PillPointer: ObservableObject {
    static let space = "pill"
    @Published var location: CGPoint?
}

private final class PillHostingView<Content: View>: NSHostingView<Content> {
    private let pointer: PillPointer
    private let hover: (Bool) -> Void
    private var area: NSTrackingArea?
    private var stopped = false

    init(rootView: Content, pointer: PillPointer, hover: @escaping (Bool) -> Void) {
        self.pointer = pointer
        self.hover = hover
        super.init(rootView: rootView)
    }

    @MainActor required init(rootView: Content) { fatalError() }
    @MainActor required init?(coder: NSCoder) { fatalError() }

    func stop() { stopped = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    private func track(_ event: NSEvent) {
        guard !stopped else { return }
        var p = convert(event.locationInWindow, from: nil)
        if !isFlipped { p.y = bounds.height - p.y }
        pointer.location = p
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        track(event)
        hover(true)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        track(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointer.location = nil
        if !stopped { hover(false) }
    }
}

private struct PillView: View {
    let commands: [AICommand]
    let text: String
    let source: SelectionText.Source
    @ObservedObject var pointer: PillPointer
    @ObservedObject var ask: AskSession
    let done: () -> Void
    let hold: (Bool) -> Void
    let asking: () -> Void
    let resized: (CGSize) -> Void
    @State private var copied = false
    @State private var translating = false

    var body: some View {
        Group {
            if ask.open {
                AskCard(ask: ask, pointer: pointer, done: done)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                bar.transition(.opacity)
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
        .environment(\.colorScheme, .dark)
    }

    private var bar: some View {
        HStack(spacing: 2) {
            button("sparkles", "Ask about this") {
                asking()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { ask.open = true }
            }
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
    }

    private func button(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PillButtonStyle(pointer: pointer))
        .help(help)
    }
}

/// Lit while the pointer (as AppKit sees it) is over it.
private struct PillButtonStyle: ButtonStyle {
    @ObservedObject var pointer: PillPointer
    var shape: AnyShape = AnyShape(Capsule())

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                GeometryReader { g in
                    let over = pointer.location.map { g.frame(in: .named(PillPointer.space)).contains($0) } ?? false
                    shape.fill(Color.white.opacity(configuration.isPressed ? 0.22 : over ? 0.13 : 0))
                        .animation(.easeOut(duration: 0.1), value: over)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
