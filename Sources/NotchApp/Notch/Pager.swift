import AppKit
import QuartzCore
import SwiftUI

/// The open notch's pages and the pill over the tab buttons, moved by Core Animation.
///
/// Each built page has its own hosting view, laid out over the visible area, and where it's drawn
/// is all Core Animation: its slot's transform holds it a whole page to the side and adds the
/// swipe, under the finger and as a slide settles (every slot on the same spring, in one
/// transaction, with the pill). So
/// SwiftUI does no work per frame, AppKit-backed controls inside the pages (scroll views, text
/// fields) move with the SwiftUI-drawn content instead of a frame apart from it, and the spring
/// runs in the render server, smooth even while the main thread is busy building a page.
@MainActor
final class PagerState: ObservableObject {
    /// The page whose neighbours are built. It only moves while nothing is sliding, so a swipe
    /// never builds or tears down a page mid-motion (a visible hitch); nil until the notch settles.
    var builtCenter: Int? { didSet { if builtCenter != oldValue { container?.syncPages() } } }
    /// The tab a change started from, kept built until the neighbours are next rebuilt.
    var fromIndex: Int? { didSet { if fromIndex != oldValue { container?.syncPages() } } }

    /// The pages to keep built: the current one, its neighbours once things are still, and the
    /// one a slide started from.
    var builtIndices: Set<Int> {
        var set: Set<Int> = [index]
        if let fromIndex { set.insert(fromIndex) }
        if let c = builtCenter { set.formUnion([c - 1, c, c + 1]) }
        return set.filter { $0 >= 0 && $0 < tabCount }
    }

    /// The finger is on the trackpad, moving the pages.
    var isSwiping = false { willSet { if (newValue || isSettling) != isMoving { objectWillChange.send() } } }
    /// A slide is springing into place.
    private(set) var isSettling = false { willSet { if (isSwiping || newValue) != isMoving { objectWillChange.send() } } }
    // (Only starting or stopping moving is announced, for views paused while pages slide, like the
    // search bar's glow: nothing else here is published, so a swipe doesn't re-render the pages.)
    var isMoving: Bool { isSwiping || isSettling }

    /// The page the layout rests on (the committed tab).
    private(set) var index = 0
    /// Which way the last slide went (1 right, -1 left), so the page that way is built first.
    private(set) var lastStep = 1
    var tabCount = 1
    /// One page's width, from the container's layout.
    var width: CGFloat = 600
    /// Where the pages are drawn relative to `index`, in points (positive: moved right). The model
    /// value; mid-spring the screen shows `visualOffset`.
    private(set) var offset: CGFloat = 0

    weak var container: PagerContainerView?
    weak var pill: TabPillView?
    /// Bumped by every slide or grab, so a superseded slide's completion does nothing.
    private var generation = 0

    /// The resting page, when the tab changes with nothing moving (opening on a tab, tabs added).
    func rest(on index: Int, count: Int) {
        tabCount = max(count, 1)
        guard !isMoving else { return }
        if index != self.index || offset != 0 {
            self.index = index
            offset = 0
            container?.farFrom = nil
            container?.syncPages()
        }
        pill?.place(progress: CGFloat(index))
    }

    /// Follows the finger.
    func drag(to offset: CGFloat) {
        if !isSwiping { beginSwipe() }
        self.offset = offset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container?.setTranslation(offset)
        pill?.place(progress: progress(for: offset))
        CATransaction.commit()
    }

    /// The finger goes down mid-slide: the pages stop where they are on screen, and the swipe
    /// carries on from there. Returns that offset.
    @discardableResult func grab() -> CGFloat {
        let current = visualOffset
        generation += 1
        isSettling = false
        container?.stopAnimations()
        pill?.stopAnimations()
        drag(to: current)
        return current
    }

    func beginSwipe() {
        isSwiping = true
        // A neighbour still waiting its turn to be built is needed now.
        container?.syncPages()
        container?.beginMotion()
    }

    /// Slides from the committed page to `newIndex`. `commit` changes the tab (the layout moves a
    /// whole page while the transform makes up for it, in one transaction, so nothing jumps); the
    /// spring then brings the transform back to zero. `velocity` is the finger's, in points per
    /// second (positive: moving right).
    func slide(to newIndex: Int, velocity: CGFloat, motion: Motion, commit: () -> Void, completion: @escaping () -> Void) {
        let old = index
        // A jump of more than one page slides the new page in from right beside the old one,
        // rather than past every page between (they aren't built: it was a run of blank pages).
        // The pill still travels the whole way, so it's clear where you went.
        let jump = newIndex - old
        if jump != 0 { lastStep = jump.signum() }
        let span = abs(jump) > 1 ? jump.signum() : jump
        let start = visualOffset + CGFloat(span) * width
        let pillStart = CGFloat(old) - visualOffset / max(width, 1)
        container?.farFrom = abs(jump) > 1 ? (old, -CGFloat(span)) : nil
        generation += 1
        let token = generation
        fromIndex = old
        isSwiping = false
        isSettling = true
        commit()
        index = newIndex
        offset = 0

        let fade = Motion.reduced && velocity == 0 && newIndex != old
        // Settled once it looks settled: the spring's tail (well under a point) doesn't hold up
        // clicks or the edge fade.
        DispatchQueue.main.asyncAfter(deadline: .now() + motion.duration) { [weak self] in
            guard let self, self.generation == token else { return }
            self.isSettling = false
            // The page a long jump started from goes back to its real place (it's hidden now).
            if self.container?.farFrom != nil {
                self.container?.farFrom = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.container?.applyLayout()
                CATransaction.commit()
            }
            self.container?.endMotion()
            completion()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container?.stopAnimations()
        pill?.stopAnimations()
        container?.syncPages()
        container?.setTranslation(0)
        pill?.place(progress: CGFloat(newIndex))
        if fade {
            // Reduce Motion: the new page fades in where it is, and the pill hops.
            container?.crossfade(duration: motion.duration)
            pill?.crossfade(duration: motion.duration)
        } else if abs(start) >= 0.5 {
            // In units of the whole distance per second, toward the target (negative: still moving away).
            let toward = start > 0 ? -velocity : velocity
            let normalized = max(-4, min(toward / abs(start), 14))
            container?.animateTranslation(from: start, motion: motion, velocity: normalized)
            pill?.animate(fromProgress: pillStart, motion: motion, velocity: normalized)
        }
        container?.beginMotion()
        // The edge fade clears over the second half of the slide, gone before the page stops.
        if !fade { container?.fadeEdgesOut(after: motion.duration * 0.45, duration: motion.duration * 0.4) }
        CATransaction.commit()
    }

    /// The notch closed: everything back at rest, with no animation.
    func reset(to index: Int) {
        generation += 1
        isSwiping = false
        isSettling = false
        container?.stopAnimations()
        pill?.stopAnimations()
        self.index = index
        offset = 0
        container?.farFrom = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container?.syncPages()
        container?.setTranslation(0)
        container?.endMotion(animated: false)
        pill?.place(progress: CGFloat(index))
        CATransaction.commit()
    }

    /// Debug: where everything is.
    var debugState: String {
        let t = container?.presentedTranslation ?? .nan
        return "PAGER index=\(index) count=\(tabCount) w=\(width) offset=\(offset) shown=\(t) swiping=\(isSwiping) settling=\(isSettling) "
            + "built=\(builtCenter.map(String.init) ?? "-") from=\(fromIndex.map(String.init) ?? "-") "
            + "container=\(container?.debugState ?? "nil") pill=\(pill?.debugState ?? "nil")"
    }

    /// The offset on screen right now (mid-spring, the presentation value).
    private var visualOffset: CGFloat { container?.presentedTranslation ?? offset }

    /// Which tab the pill is over: `index` at rest, fractional between.
    private func progress(for offset: CGFloat, index: Int? = nil) -> CGFloat {
        CGFloat(index ?? self.index) - offset / max(width, 1)
    }
}

/// Holds the pages and moves them. Each page has its own slot, laid out over the visible area,
/// that clips it and moves it (the slot layer's sublayer transform: the page's place beside the
/// current one plus the swipe). SwiftUI decides what to draw from the page's place in its
/// clipping layer, leaving that layer's own transform out, so every page is drawn whole wherever
/// it's moved; with the motion anywhere else, a page coming in was drawn only in part, or blank.
final class PagerContainerView: NSView {
    let pager: PagerState
    private let makePage: (NotchTab) -> AnyView
    private var tabs: [NotchTab] = []
    private var slots: [NotchTab: PageSlotView] = [:]
    /// The swipe, in points, on top of each page's place (the model value).
    private var shared: CGFloat = 0
    /// After a jump of several pages, the page it started from sits right beside the new one
    /// (in pages: -1 left, 1 right) instead of where it really is.
    var farFrom: (index: Int, place: CGFloat)?
    /// Fades the edges while pages move, so a page leaving dims as it goes.
    private var edgeMask: CAGradientLayer?

    init(pager: PagerState, makePage: @escaping (NotchTab) -> AnyView) {
        self.pager = pager
        self.makePage = makePage
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor func update(tabs: [NotchTab]) {
        guard tabs != self.tabs else { return }
        self.tabs = tabs
        syncPages()
    }

    override func layout() {
        super.layout()
        MainActor.assumeIsolated {
            if bounds.width > 0 { pager.width = bounds.width }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyLayout()
            edgeMask?.frame = bounds
            CATransaction.commit()
        }
    }

    /// Builds the pages that should be up and lets the rest go, then places them.
    @MainActor func syncPages() {
        var wanted: [NotchTab: Int] = [:]
        for i in pager.builtIndices where i < tabs.count { wanted[tabs[i]] = i }
        for (tab, slot) in slots where wanted[tab] == nil {
            slot.removeFromSuperview()
            slots[tab] = nil
        }
        // Missing pages, nearest first and the next one before the previous one. At rest they're
        // built one per pass, a moment apart: building both neighbours in one go was the last
        // dropped frame left after a slide. A swipe needs them now, so it builds them all.
        // The way the last slide went is the way the next one most likely goes.
        let ahead = pager.lastStep
        let missing = wanted.filter { slots[$0.key] == nil }
            .sorted { a, b in
                let da = abs(a.value - pager.index), db = abs(b.value - pager.index)
                if da != db { return da < db }
                return (a.value - pager.index).signum() == ahead
            }
            .map(\.key)
        let now = pager.isMoving ? missing : Array(missing.prefix(1))
        var added = false
        for tab in now {
            let slot = PageSlotView(host: PagesHostingView(rootView: makePage(tab)))
            slot.frame = bounds
            addSubview(slot)
            slots[tab] = slot
            added = true
        }
        if now.count < missing.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                MainActor.assumeIsolated { self?.syncPages() }
            }
        }
        applyLayout()
        // A new page is left showing (off to the side, clipped away) long enough to be drawn
        // once, so it has its picture when a swipe brings it in; then it's hidden like the others.
        if added {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for slot in self.slots.values { slot.fresh = false }
                    self.updateHidden()
                }
            }
        }
    }

    /// Where a page sits when nothing is swiped: a whole page per tab from the current one.
    private func base(_ tab: NotchTab) -> CGFloat {
        let i = tabs.firstIndex(of: tab) ?? pager.index
        if let farFrom, farFrom.index == i { return farFrom.place * bounds.width }
        return CGFloat(i - pager.index) * bounds.width
    }

    /// Every page in its place, with the swipe on top.
    @MainActor func applyLayout() {
        for (tab, slot) in slots {
            if slot.frame != bounds { slot.frame = bounds }
            slot.place(base(tab) + shared)
        }
        updateHidden()
    }

    /// At rest only the current page is shown: the others sit right under it in AppKit's eyes,
    /// and their hover areas and cursors would catch the pointer over the current page.
    @MainActor func updateHidden() {
        let current = pager.index < tabs.count ? tabs[pager.index] : nil
        for (tab, slot) in slots {
            let hide = !(pager.isMoving || tab == current || slot.fresh)
            if slot.isHidden != hide { slot.isHidden = hide }
        }
    }

    /// Passes a pointer move to the page showing (see `PagesHostingView.pointerMoved`).
    @MainActor func pointerMoved(_ event: NSEvent) {
        guard !pager.isMoving, pager.index < tabs.count, let slot = slots[tabs[pager.index]] else { return }
        (slot.host as? PagesHostingView<AnyView>)?.pointerMoved(event)
    }

    /// The notch closed: exits held back for the pointer still being over a page go through now,
    /// or a card would still look hovered the next time it opens.
    @MainActor func releaseHover() {
        for slot in slots.values { (slot.host as? PagesHostingView<AnyView>)?.releaseHeldExits() }
    }

    /// Clicks go to the current page only, and to nothing while pages move (they'd land on the
    /// layout's places, not where things are drawn).
    override func hitTest(_ point: NSPoint) -> NSView? {
        MainActor.assumeIsolated {
            guard !pager.isMoving, pager.index < tabs.count, let slot = slots[tabs[pager.index]] else { return nil }
            let p = superview.map { convert(point, from: $0) } ?? point
            guard bounds.contains(p) else { return nil }
            return slot.hitTest(p)
        }
    }

    var debugState: String {
        "\(frame) shared=\(shared) pages=" + slots.map { tab, slot in
            "\(tab.rawValue)\(slot.isHidden ? "(hidden)" : "")@\(slot.layer?.sublayerTransform.m41 ?? .nan)"
        }.sorted().joined(separator: ",")
    }

    /// Moves every page by the swipe.
    @MainActor func setTranslation(_ x: CGFloat) {
        shared = x
        for (tab, slot) in slots { slot.place(base(tab) + x) }
    }

    /// The swipe as it is on screen (mid-spring, the presentation value).
    @MainActor var presentedTranslation: CGFloat? {
        guard pager.index < tabs.count, let tab = Optional(tabs[pager.index]), let slot = slots[tab], let layer = slot.layer else { return nil }
        return (layer.presentation() ?? layer).sublayerTransform.m41 - base(tab)
    }

    @MainActor func stopAnimations() {
        let now = presentedTranslation ?? shared
        var moving = false
        for slot in slots.values { if slot.layer?.animation(forKey: "slide") != nil { moving = true }; slot.layer?.removeAnimation(forKey: "slide") }
        if moving { setTranslation(now) }
    }

    /// Springs the swipe from `start` to zero; every page takes the same spring.
    @MainActor func animateTranslation(from start: CGFloat, motion: Motion, velocity: CGFloat) {
        for (tab, slot) in slots {
            let a = motion.caSpring(keyPath: "sublayerTransform.translation.x", velocity: velocity)
            a.fromValue = base(tab) + start
            a.toValue = base(tab) + shared
            slot.layer?.add(a, forKey: "slide")
        }
    }

    func crossfade(duration: Double) {
        let t = CATransition()
        t.type = .fade
        t.duration = duration
        layer?.add(t, forKey: "fade")
    }

    private static let restingStops: [NSNumber] = [-0.01, 0, 1, 1.01]
    private static let movingStops: [NSNumber] = [0, 0.1, 0.9, 1]

    /// Shows the neighbours and fades the edges in as pages start to move.
    @MainActor func beginMotion() {
        updateHidden()
        guard let layer else { return }
        if edgeMask == nil {
            let mask = CAGradientLayer()
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            mask.locations = Self.restingStops
            mask.frame = bounds
            layer.mask = mask
            edgeMask = mask
        }
        animateStops(to: Self.movingStops)
    }

    /// And out once they're still; the mask goes, so nothing is drawn offscreen at rest.
    @MainActor func endMotion(animated: Bool = true) {
        updateHidden()
        guard let mask = edgeMask else { return }
        // Already faded out as the page arrived (`fadeEdgesOut`): nothing left to animate.
        guard animated, mask.locations != Self.restingStops else {
            layer?.mask = nil
            edgeMask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.edgeMask === mask, !self.pager.isMoving else { return }
                self.layer?.mask = nil
                self.edgeMask = nil
            }
        }
        animateStops(to: Self.restingStops)
        CATransaction.commit()
    }

    /// Clears the edges while a settling page is still arriving, so they're gone as it lands
    /// rather than a moment after.
    func fadeEdgesOut(after delay: Double, duration: Double) {
        guard let mask = edgeMask else { return }
        // In (if a click started it, from nothing), held, then out: one animation, so the fade-in
        // isn't cut short.
        let total = delay + duration
        let fadeIn = min(0.12, delay)
        let a = CAKeyframeAnimation(keyPath: "locations")
        a.values = [(mask.presentation() ?? mask).locations ?? Self.restingStops, Self.movingStops, Self.movingStops, Self.restingStops]
        a.keyTimes = [0, fadeIn / total, delay / total, 1].map { NSNumber(value: $0) }
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut)]
        a.duration = total
        mask.locations = Self.restingStops
        mask.add(a, forKey: "locations")
    }

    private func animateStops(to stops: [NSNumber]) {
        guard let mask = edgeMask else { return }
        let a = CABasicAnimation(keyPath: "locations")
        a.fromValue = (mask.presentation() ?? mask).locations
        a.toValue = stops
        a.duration = 0.18
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mask.locations = stops
        mask.add(a, forKey: "locations")
    }
}

/// One page: laid out over the visible area, clipped to it, and moved inside it.
final class PageSlotView: NSView {
    let host: NSView
    /// Just built: kept showing until it's been drawn once.
    var fresh = true

    init(host: NSView) {
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if host.frame != bounds { host.frame = bounds }
    }

    func place(_ x: CGFloat) {
        guard layer?.sublayerTransform.m41 != x else { return }
        layer?.sublayerTransform = CATransform3DMakeTranslation(x, 0, 0)
    }
}

/// A page's hosting view.
final class PagesHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// AppKit follows the pointer for SwiftUI's hover with tracking areas, and places them where
    /// the page would be without the header above it: they end about a header's height short
    /// of the page's bottom. Hover stopped there, so buttons shown on hover near the bottom of
    /// a page (a clip's Paste, Pin and Remove) went away as the pointer reached them. So an
    /// "exited" that comes while the pointer is still over the page waits until it really
    /// leaves, and the notch passes every pointer move on (`pointerMoved`).
    private var heldExits: [NSEvent] = []
    /// The page has been told the pointer is over it (by AppKit, or here for the strip AppKit misses).
    private var entered = false
    /// AppKit's last "entered" for each of SwiftUI's areas, to say it again for the missed strip
    /// (SwiftUI only listens to events from its own areas).
    private var enters: [ObjectIdentifier: NSEvent] = [:]

    override func mouseEntered(with event: NSEvent) {
        entered = true
        if let area = event.trackingArea { enters[ObjectIdentifier(area)] = event }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            heldExits.append(event)
            return
        }
        heldExits = []
        entered = false
        super.mouseExited(with: event)
    }

    func releaseHeldExits() {
        guard !heldExits.isEmpty else { return }
        let held = heldExits
        heldExits = []
        entered = false
        held.forEach { super.mouseExited(with: $0) }
    }

    /// A pointer move over the notch's window, wherever AppKit thinks the page is.
    func pointerMoved(_ event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            // Come in from below, through the strip AppKit doesn't count: it never said "entered".
            if !entered {
                let live = Set(trackingAreas.map(ObjectIdentifier.init))
                enters = enters.filter { live.contains($0.key) }
                entered = !enters.isEmpty
                enters.values.forEach { super.mouseEntered(with: $0) }
            }
            mouseMoved(with: event)
        } else {
            releaseHeldExits()
        }
    }
}

// Spelled out rather than `@Entry`: that macro's plugin ships with Xcode, not the Command Line Tools.
private struct NotchPageKey: EnvironmentKey {
    static let defaultValue: NotchTab? = nil
}

extension EnvironmentValues {
    /// The page a view is on (unset outside the open notch's pages).
    var notchPage: NotchTab? {
        get { self[NotchPageKey.self] }
        set { self[NotchPageKey.self] = newValue }
    }
}

/// The open notch's pages, hosted in AppKit so Core Animation can move them.
struct PagerHost: NSViewRepresentable {
    @ObservedObject var viewModel: NotchViewModel
    let tabs: [NotchTab]
    let index: Int
    let page: (NotchTab) -> AnyView

    func makeNSView(context: Context) -> PagerContainerView {
        let pager = viewModel.pager
        let page = self.page
        let view = PagerContainerView(pager: pager) { tab in
            AnyView(page(tab)
                // Pages have their own hosting views, so the notch's menu is added to each, with
                // the page's settings on top. Things with a menu of their own (a file, a clip) keep it.
                .contextMenu { NotchMenu(page: tab) }
                .environment(\.notchPage, tab)
                .notchEnvironment()
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark))
        }
        pager.container = view
        viewModel.pagesHost = view
        pager.tabCount = tabs.count
        view.update(tabs: tabs)
        pager.rest(on: index, count: tabs.count)
        return view
    }

    /// Takes the space it's offered. Left to itself, SwiftUI asked AppKit for the pager's fitting
    /// size on every layout pass, and AppKit worked it out from every view of every built page:
    /// about a tenth of the main thread's time while typing in Search.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PagerContainerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ view: PagerContainerView, context: Context) {
        let pager = viewModel.pager
        pager.tabCount = tabs.count
        view.update(tabs: tabs)
        pager.rest(on: index, count: tabs.count)
    }
}

/// The pill behind the selected tab button, with a bright copy of the icons masked to it, so the
/// lit icon is always exactly the one under the pill, even halfway through a swipe.
final class TabPillView: NSView {
    private let pill = CALayer()
    private let fill = CAGradientLayer()
    private let stroke = CAGradientLayer()
    private let strokeMask = CAShapeLayer()
    private let litMask = CALayer()
    private let lit: NSHostingView<LitIcons>
    private var buttonWidth: CGFloat = 40
    private var spacing: CGFloat = 3
    private let height: CGFloat = 22

    init() {
        lit = NSHostingView(rootView: LitIcons(icons: [], buttonWidth: 40, spacing: 3))
        lit.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(lit)
        fill.colors = [NSColor.white.withAlphaComponent(0.13).cgColor, NSColor.white.withAlphaComponent(0.08).cgColor]
        stroke.colors = [NSColor.white.withAlphaComponent(0.26).cgColor, NSColor.white.withAlphaComponent(0.09).cgColor]
        for g in [fill, stroke] {
            g.startPoint = CGPoint(x: 0.5, y: 1) // top to bottom in this (unflipped) view
            g.endPoint = CGPoint(x: 0.5, y: 0)
            pill.addSublayer(g)
        }
        strokeMask.fillColor = nil
        strokeMask.strokeColor = NSColor.white.cgColor
        strokeMask.lineWidth = 1
        stroke.mask = strokeMask
        pill.masksToBounds = true
        litMask.backgroundColor = NSColor.black.cgColor
        layer?.insertSublayer(pill, at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(icons: [String], buttonWidth: CGFloat, spacing: CGFloat) {
        let changed = buttonWidth != self.buttonWidth || spacing != self.spacing || lit.rootView.icons != icons
        self.buttonWidth = buttonWidth
        self.spacing = spacing
        if changed { lit.rootView = LitIcons(icons: icons, buttonWidth: buttonWidth, spacing: spacing) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(x: 0, y: 0, width: buttonWidth, height: height)
        pill.bounds = bounds
        pill.cornerRadius = height / 2
        fill.frame = bounds
        stroke.frame = bounds
        strokeMask.frame = bounds
        strokeMask.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: height / 2 - 0.5, cornerHeight: height / 2 - 0.5, transform: nil)
        litMask.bounds = bounds
        litMask.cornerRadius = height / 2
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        lit.frame = bounds
        if lit.layer?.mask !== litMask { lit.layer?.mask = litMask }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.position.y = bounds.midY
        litMask.position.y = bounds.midY
        CATransaction.commit()
    }

    private func x(for progress: CGFloat) -> CGFloat {
        progress * (buttonWidth + spacing) + buttonWidth / 2
    }

    /// Puts the pill over a tab (fractional between two), with no animation.
    func place(progress: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.position.x = x(for: progress)
        litMask.position.x = pill.position.x
        CATransaction.commit()
    }

    var debugState: String { "\(frame) pillX=\(pill.position.x) shownX=\((pill.presentation() ?? pill).position.x) win=\(window != nil)" }

    func stopAnimations() {
        for l in [pill, litMask] where l.animation(forKey: "slide") != nil {
            let current = (l.presentation() ?? l).position
            l.removeAnimation(forKey: "slide")
            l.position = current
        }
    }

    /// From a fractional tab to where the model now is, on the pages' own spring.
    @MainActor func animate(fromProgress: CGFloat, motion: Motion, velocity: CGFloat) {
        for l in [pill, litMask] {
            let a = motion.caSpring(keyPath: "position.x", velocity: velocity)
            a.fromValue = x(for: fromProgress)
            a.toValue = l.position.x
            l.add(a, forKey: "slide")
        }
    }

    func crossfade(duration: Double) {
        let t = CATransition()
        t.type = .fade
        t.duration = duration
        layer?.add(t, forKey: "fade")
        lit.layer?.add(t, forKey: "fade")
    }
}

/// The tab icons at full brightness, shown only through the pill.
struct LitIcons: View {
    let icons: [String]
    let buttonWidth: CGFloat
    let spacing: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(icons.enumerated()), id: \.offset) { _, icon in
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: buttonWidth, height: 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }
}

/// The pill, placed by SwiftUI over the tab buttons and moved by the pager.
struct TabPill: NSViewRepresentable {
    let pager: PagerState
    let icons: [String]
    let buttonWidth: CGFloat
    let spacing: CGFloat
    let index: Int

    func makeNSView(context: Context) -> TabPillView {
        let view = TabPillView()
        view.configure(icons: icons, buttonWidth: buttonWidth, spacing: spacing)
        pager.pill = view
        view.place(progress: CGFloat(index))
        return view
    }

    /// The frame SwiftUI gives it (never measured by AppKit).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TabPillView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ view: TabPillView, context: Context) {
        view.configure(icons: icons, buttonWidth: buttonWidth, spacing: spacing)
        pager.pill = view
        if !pager.isMoving { view.place(progress: CGFloat(index)) }
    }
}
