import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A small floating Shelf at the pointer, summoned by shaking a file mid-drag: drop it there instead
/// of carrying it up to the notch. Files dropped in are quick drops on the same Shelf; the tray keeps
/// showing them as a pile to drag out again, so files gathered from several places leave together.
/// It goes when it's emptied or closed, or a few seconds after the pointer leaves it empty.
@MainActor
final class ShelfTray: ObservableObject {
    static let shared = ShelfTray()

    /// The Shelf's files this tray holds, newest first.
    @Published private(set) var ids: [UUID] = []
    @Published var hovered = false
    @Published var targeted = false {
        didSet { if targeted, !oldValue { Haptics.level() } }
    }

    /// The notch's own drop area (its bins are there): shaking over it does nothing new.
    var isOverNotch: (NSPoint) -> Bool = { _ in false }

    static let card = CGSize(width: 112, height: 112)
    static let radius: CGFloat = 26
    /// Room around the card for its shadow.
    private static let margin: CGFloat = 20
    /// How long an empty tray waits once the pointer has left it.
    private static let linger: TimeInterval = 3

    private var panel: ShelfTrayPanel?
    private var awaySince: Date?
    private var cancellable: AnyCancellable?

    private init() {
        // Files that leave the Shelf (dragged out, removed there) leave the tray too.
        cancellable = ShelfStore.shared.$items.sink { [weak self] items in
            guard let self, !self.ids.isEmpty else { return }
            let left = self.ids.filter { id in items.contains { $0.id == id } }
            guard left != self.ids else { return }
            self.ids = left
            if left.isEmpty { DispatchQueue.main.async { self.close() } }
        }
    }

    var items: [ShelfItem] {
        let all = ShelfStore.shared.items
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    var isShowing: Bool { panel != nil }

    /// The card's frame on screen.
    var cardFrame: NSRect? { panel.map { $0.frame.insetBy(dx: Self.margin, dy: Self.margin) } }

    /// The pointer was shaken during a drag from another app.
    func shaken(at p: NSPoint) {
        let s = AppSettings.shared
        guard s.shelfEnabled, s.shakeTray, !isOverNotch(p) else { return }
        // The Shelf takes files (and screenshots dragged from their thumbnail, which carry one).
        guard NSPasteboard(name: .drag).canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        DebugHooks.log("TRAY shaken at \(Int(p.x)),\(Int(p.y))")
        show(at: p)
    }

    /// Brings the tray up centred on `p` (or moves the one that's up there).
    func show(at p: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
        let size = CGSize(width: Self.card.width + 2 * Self.margin, height: Self.card.height + 2 * Self.margin)
        var frame = NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
        if let visible = screen?.visibleFrame.insetBy(dx: -Self.margin, dy: -Self.margin) {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        }
        frame = frame.integral
        awaySince = nil
        Haptics.align()

        if let panel {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
            return
        }
        let panel = ShelfTrayPanel(contentRect: frame)
        let root = ShelfTrayView(tray: self)
            .padding(Self.margin)
            .environmentObject(ShelfStore.shared)
            .environmentObject(AppSettings.shared)
            .environment(\.colorScheme, .dark)
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        let host = FirstMouseHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        springIn(container)
    }

    /// A short spring out of the pointer: the whole window's content (glass and all) scales as one.
    private func springIn(_ view: NSView) {
        guard let layer = view.layer else { return }
        let reduced = Motion.reduced
        let s: CGFloat = reduced ? 1 : 0.55
        // The layer scales about its anchor; this moves the pivot to the middle.
        let pivot = CGPoint(x: layer.bounds.width * (0.5 - layer.anchorPoint.x), y: layer.bounds.height * (0.5 - layer.anchorPoint.y))
        var from = CATransform3DMakeTranslation(pivot.x * (1 - s), pivot.y * (1 - s), 0)
        from = CATransform3DScale(from, s, s, 1)
        let grow = Motion(duration: 0.34, bounce: 0.3).caSpring(keyPath: "sublayerTransform")
        grow.fromValue = NSValue(caTransform3D: from)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(grow, forKey: "springIn")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.15
        fade.fillMode = .backwards
        layer.add(fade, forKey: "fadeIn")
    }

    /// Puts the tray away. Its files stay on the Shelf.
    func close() {
        guard let panel else { return }
        self.panel = nil
        ids = []
        hovered = false
        targeted = false
        awaySince = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.close()
            }
        })
    }

    /// Takes what's being dragged onto the tray, as the notch's Shelf bin does.
    func takeDrop() -> Bool {
        let start = Date()
        guard ShelfStore.shared.addDrop(from: NSPasteboard(name: .drag)) else { return false }
        hold(since: start)
        Haptics.level()
        return true
    }

    /// Debug: files put on the Shelf (off the clipboard) and in the tray, as if dropped on it.
    func debugAdd(_ urls: [URL]) {
        let start = Date()
        ShelfStore.shared.add(urls, copy: false)
        hold(since: start)
    }

    /// The Shelf's files added (or dropped again) since `start` join the pile, on top.
    private func hold(since start: Date) {
        let new = ShelfStore.shared.items.filter { $0.added >= start }.map(\.id)
        withAnimation(Motion.small.animation) { ids = new + ids.filter { !new.contains($0) } }
    }

    /// Opens the Shelf in the notch (a click on the pile).
    func openShelf() {
        UserDefaults.standard.set(ShelfPane.shelf.rawValue, forKey: "shelf.pane")
        NotchPresenter.shared.primary?.open(tab: .shelf, takeKeyboard: false)
    }

    /// Follows the pointer (from the app's mouse tracker): hover for the close button, and an empty
    /// tray goes a little while after the pointer has left it.
    func handleMouse() {
        guard let card = cardFrame, !DebugHooks.pinned else { return }
        let inside = card.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
        if hovered != inside { withAnimation(Motion.small.animation) { hovered = inside } }
        guard ids.isEmpty, !inside, !targeted else { awaySince = nil; return }
        let since = awaySince ?? Date()
        awaySince = since
        if Date().timeIntervalSince(since) > Self.linger { close() }
    }

    func debugState() -> String {
        "TRAY showing=\(isShowing) frame=\(cardFrame.map { NSStringFromRect($0) } ?? "-") files=\(items.map(\.name)) hovered=\(hovered) targeted=\(targeted)"
    }

    /// Debug: the tray's own views drawn into a PNG (no glass: that's the window server's).
    func debugSnapshot(to url: URL) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The tray's window: floating over other apps, and never taking focus from the one being dragged from.
final class ShelfTrayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // As the notch's panel does: re-applied, it registers as non-activating with the window server.
        styleMask = [.borderless, .nonactivatingPanel]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct ShelfTrayView: View {
    @ObservedObject var tray: ShelfTray
    @EnvironmentObject private var shelf: ShelfStore
    @EnvironmentObject private var settings: AppSettings
    @State private var moveFrom: (mouse: NSPoint, origin: NSPoint)?

    var body: some View {
        let items = tray.items
        let shape = RoundedRectangle(cornerRadius: ShelfTray.radius, style: .circular)
        ZStack {
            TrayGlass(look: DynamicGlass.Look(settings.glassLevel), glass: settings.usesGlass)
            shape.fill(tray.targeted ? Color.orange.opacity(0.26) : .clear)
            shape.strokeBorder(tray.targeted ? Color.orange.opacity(0.9) : .clear, lineWidth: 1.5)
            if items.isEmpty { waiting } else { pile(items) }
        }
        .frame(width: ShelfTray.card.width, height: ShelfTray.card.height)
        .overlay(alignment: .topLeading) {
            if tray.hovered {
                Button { tray.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .help(items.isEmpty ? "Close" : "Close · the files stay on the Shelf")
                .padding(8)
                .transition(.opacity)
            }
        }
        .contentShape(shape)
        // Dragged by its background: the window follows the pointer itself (not the gesture's own
        // coordinates, which move with the window).
        .gesture(DragGesture(minimumDistance: 2).onChanged { _ in
            guard let window = NSApp.windows.first(where: { $0 is ShelfTrayPanel && $0.isVisible }) else { return }
            let mouse = NSEvent.mouseLocation
            let from = moveFrom ?? (mouse, window.frame.origin)
            moveFrom = from
            window.setFrameOrigin(NSPoint(x: from.origin.x + mouse.x - from.mouse.x, y: from.origin.y + mouse.y - from.mouse.y))
        }.onEnded { _ in moveFrom = nil })
        .onDrop(of: [UTType.fileURL], isTargeted: $tray.targeted) { _ in tray.takeDrop() }
        .animation(Motion.small.animation, value: tray.targeted)
    }

    /// Empty: a target to drop on.
    private var waiting: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tray.targeted ? .white : .orange)
                .frame(width: 38, height: 38)
                .background(Circle().fill(tray.targeted ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color.orange.opacity(0.2))))
                .scaleEffect(tray.targeted ? 1.08 : 1)
                .symbolEffect(.bounce, value: tray.targeted)
            Text("Shelf")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    /// Holding files: the pile drags them all out (⌘ moves the originals, ⌥ keeps them here).
    private func pile(_ items: [ShelfItem]) -> some View {
        VStack(spacing: 6) {
            StackPile(items: Array(items.prefix(3)), size: 42)
                .frame(width: 72, height: 58)
                .contentShape(Rectangle())
                .overlay(FileDragSource(items: items, onClick: tray.openShelf))
                .help(items.count == 1 ? "Drag into any app · ⌥ keeps it on the Shelf" : "Drag all \(items.count) files · ⌥ keeps them on the Shelf")
            Text(items.count == 1 ? items[0].name : "\(items.count) files")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
        }
        .padding(.top, 4)
        .animation(Motion.small.animation, value: items.map(\.id))
    }
}

/// The tray's surface: a small piece of the notch's dark glass, its rim bending what's behind all
/// the way round, under a shade dark enough for white text. Black when the notch has no glass.
/// Its layers never move on their own (the window's content scales as one), so they can't drift
/// from the SwiftUI drawn above them.
private struct TrayGlass: NSViewRepresentable {
    let look: DynamicGlass.Look
    let glass: Bool

    func makeNSView(context: Context) -> GlassView { GlassView() }

    func updateNSView(_ view: GlassView, context: Context) {
        view.state = (look, glass)
        view.relayout()
    }

    final class GlassView: NSView {
        var state: (look: DynamicGlass.Look, glass: Bool)?
        private let root = CALayer()
        private let clip = CALayer()
        private let shade = CALayer()
        private let rim = CAShapeLayer()
        private var lens: GlassLens.Lens?

        init() {
            super.init(frame: .zero)
            layer = root
            wantsLayer = true
            if let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type, LiquidGlass.isAvailable {
                let backdrop = layerClass.init()
                backdrop.setValue(true, forKey: "windowServerAware")
                backdrop.setValue(UUID().uuidString, forKey: "groupName")
                backdrop.setValue(true, forKey: "disableFilterCache")
                backdrop.setValue(32, forKey: "marginWidth")
                clip.masksToBounds = true
                clip.cornerCurve = .circular
                clip.addSublayer(backdrop)
                lens = GlassLens.attach(to: backdrop, blur: 0.4)
                root.addSublayer(clip)
            }
            shade.cornerCurve = .circular
            rim.fillColor = nil
            rim.lineWidth = 1
            root.addSublayer(shade)
            root.addSublayer(rim)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            relayout()
        }

        func relayout() {
            guard let (look, glass) = state, bounds.width > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let scale = window?.backingScaleFactor ?? 2
            for l in [root, clip, shade, rim] { l.contentsScale = scale }
            let r = ShelfTray.radius
            let on = glass && lens != nil
            clip.isHidden = !on
            clip.frame = bounds
            clip.cornerRadius = r
            clip.sublayers?.first?.frame = clip.bounds
            if let lens, on {
                lens.element.frame = clip.bounds
                lens.element.cornerRadius = r
                lens.element.superlayer?.frame = clip.bounds
                // A small card's bend: shallow enough not to turn the page behind upside down.
                lens.tune(look, band: bounds.height * 0.6)
            }
            // A dark glass bottle: the level's shade, raised the way a small card's is so white text reads.
            shade.frame = bounds
            shade.cornerRadius = r
            shade.backgroundColor = NSColor.black.withAlphaComponent(on ? look.shade + (1 - look.shade) * 0.5 : 1).cgColor
            rim.frame = bounds
            rim.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: r - 0.5, cornerHeight: r - 0.5, transform: nil)
            rim.strokeColor = NSColor.white.withAlphaComponent(on ? look.rim * 0.6 : 0.12).cgColor
        }
    }
}
