import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var media: MediaController
    @EnvironmentObject private var activity: ActivityCenter
    @EnvironmentObject private var tasks: TaskStore // collapsed width depends on the open count
    @EnvironmentObject private var timer: TimerStore // and on whether a timer is running
    @EnvironmentObject private var assistant: AssistantStore // …and on running searches
    @ObservedObject private var live = LiveActivities.shared // …and on the pinned live activities
    @ObservedObject private var captions = CaptionStrip.shared // …and on live captions hanging below
    @ObservedObject private var speed = SpeedTest.shared // …and on a running speed test
    @ObservedObject private var videos = VideoDownloader.shared // …and on a video download
    @EnvironmentObject private var shelf: ShelfStore // collapsed height grows for the stack of quick drops

    var body: some View {
        let vm = viewModel
        // Open, the bottom corners are true quarter circles: the glass is drawn with those.
        let body = vm.bodySize
        // Glass wherever the notch has grown past the hardware notch: open (its bottom third), or
        // closed but dropped down a little (a Banner, the shelf's stack, a peek, captions), where
        // everything below the notch itself is glass.
        let extended = !vm.isOpen && vm.shapeSize.height > vm.notchSize.height + 4
        let glass = settings.usesGlass && (vm.isOpen ? vm.overlay != .teleprompter : extended)
        // The black part, as a fraction of the height: two thirds open, the notch's own height closed.
        let look = DynamicGlass.Look(settings.glassLevel)
        let solid = vm.isOpen ? look.solid : min(0.9, (vm.notchSize.height + 2) / max(vm.shapeSize.height, 1))
        // With glass, the bottom corners are true quarter circles: the glass is drawn with those.
        let shape = NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius,
                               roundness: vm.isOpen || glass ? NotchShape.circle : 1.0 / 3)

        let notch = ZStack(alignment: .top) {
            // Without glass the notch is SwiftUI's own black. With glass, black and glass alike are
            // drawn by NotchSurface (below), and this is only there under it once settled, for the
            // shadow: a SwiftUI shape and a Core Animation one don't land on screen on the same
            // frame, so mid-spring this one would show as a second edge out of step with the first.
            if !settings.usesGlass || (vm.isSettled && !glass) {
                shape.fill(Color.black)
                    .transition(.identity)
                    // The shadow is only drawn once the shape has settled: re-rendering a large
                    // blurred shadow on every frame of the spring is what made opening feel heavy.
                    // For the same reason it goes at once when closing, rather than fading out.
                    .shadow(color: .black.opacity(vm.isSettled && settings.showShadow && !glass ? 0.6 : 0), radius: 14, y: 6)
                    .animation(vm.isSettled ? .easeOut(duration: 0.2) : nil, value: vm.isSettled)
            }

            // Content is laid out once at its final size and revealed by the growing shape,
            // instead of being re-laid out on every animation frame.
            Group {
                if vm.isOpen {
                    OpenNotchView(viewModel: vm)
                        .frame(width: vm.openSize.width, height: vm.openSize.height, alignment: .top)
                        .transition(.asymmetric(
                            // A fade, not a scale: scaling would resize every AppKit-backed control
                            // inside on each frame of the opening animation.
                            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.04)),
                            removal: .opacity.animation(.easeOut(duration: 0.1))))
                } else {
                    CollapsedNotchView(viewModel: vm)
                        .frame(width: body.width, height: body.height, alignment: .top)
                        .transition(.opacity.animation(.easeInOut(duration: 0.18)))
                }
            }
            .frame(width: vm.shapeSize.width, height: vm.shapeSize.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: vm.shapeSize.width, height: vm.shapeSize.height)
        .contentShape(shape)
        .onTapGesture {
            if !vm.isOpen { vm.open() }
        }
        .contextMenu {
            // Open on a page (the tab row, the edges): that page's settings first.
            NotchMenu(page: vm.isOpen && vm.overlay == nil && !vm.mirror ? vm.tab : nil)
        }

        ZStack(alignment: .top) {
            // Dynamic Glass: black at the notch, the bottom third Liquid Glass. Black, shade, rim and
            // glass are one layer tree, laid out together in a single transaction, so they can't
            // drift apart; it stays in place whenever glass is on (fading between black and glass)
            // so it takes the same spring as the content instead of appearing at its final size.
            if settings.usesGlass {
                NotchSurface(shape: shape, size: vm.shapeSize, glass: glass ? 1 : 0, solid: solid, look: look, settled: vm.isSettled)
                    .allowsHitTesting(false)
            }
            notch
        }
        .animation(vm.isOpen ? settings.openAnimation : settings.closeAnimation, value: vm.isOpen)
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: vm.collapsedSize)
        .animation(.spring(response: 0.45, dampingFraction: 0.84), value: vm.openSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// The notch's right-click menu: the page's own settings when one is showing, then Glances,
/// Settings and Quit.
struct NotchMenu: View {
    let page: NotchTab?

    var body: some View {
        if let page {
            MenuItem("Edit \(page.title)…", page.icon) { SettingsWindowController.shared.show(pane: page.settingsPane) }
        }
        MenuItem("Edit Glances…", "capsule.on.rectangle") { SettingsWindowController.shared.show(pane: .live) }
        MenuItem("Settings…", "gearshape") { SettingsWindowController.shared.show() }
        Divider()
        MenuItem("Quit NotchApp", "power") { NSApp.terminate(nil) }
    }
}

/// Black at the notch, melting into glass: solid through the top two thirds, then the bottom
/// third Liquid Glass (the desktop shows through, bent at the rim), with a light along its edge.
enum DynamicGlass {
    /// One level of glass. The blur stays the same for all of them: clear glass, never frosted.
    struct Look: Equatable {
        /// How far down the open notch stays black (a fraction of its height).
        var solid: CGFloat
        /// The shade left over the glass at the rim, and how quickly it clears on the way there
        /// (the width of the fade's shoulder, as a fraction of it: smaller clears sooner).
        var shade: CGFloat
        var fade: CGFloat
        /// How far the rim bends what's behind, and over how many points inside the edge.
        var refraction: Double
        var refractionHeight: Double
        /// The light caught along the top of the rim, and the fine line along its edge.
        var highlight: Double
        var rim: CGFloat

        init(_ level: AppSettings.GlassLevel) {
            switch level {
            case .tinted:
                self.init(solid: 0.7, shade: 0.68, fade: 0.6, refraction: -45, refractionHeight: 16, highlight: 0.3, rim: 0.26)
            case .balanced:
                self.init(solid: 0.62, shade: 0.46, fade: 0.58, refraction: -60, refractionHeight: 20, highlight: 0.4, rim: 0.32)
            case .airy:
                self.init(solid: 0.54, shade: 0.26, fade: 0.53, refraction: -80, refractionHeight: 28, highlight: 0.5, rim: 0.42)
            case .clear:
                // A shallower bend than Airy's: deeper, over this much glass, it squeezes the page
                // into streaks along the rim instead of magnifying it.
                self.init(solid: 0.42, shade: 0.08, fade: 0.46, refraction: -70, refractionHeight: 24, highlight: 0.7, rim: 0.55)
            }
        }

        init(solid: CGFloat, shade: CGFloat, fade: CGFloat, refraction: Double, refractionHeight: Double, highlight: Double, rim: CGFloat) {
            self.solid = solid
            self.shade = shade
            self.fade = fade
            self.refraction = refraction
            self.refractionHeight = refractionHeight
            self.highlight = highlight
            self.rim = rim
        }

        static func == (a: Look, b: Look) -> Bool {
            a.solid == b.solid && a.shade == b.shade && a.fade == b.fade && a.refraction == b.refraction
                && a.refractionHeight == b.refractionHeight && a.highlight == b.highlight && a.rim == b.rim
        }
    }

    /// Points of glass below which the surface is a small card (a Banner, a peek, captions), whose
    /// text sits on the glass itself rather than above it.
    static let roomy: CGFloat = 110

    /// Dark enough to read white text over anything, clearing toward the rim so the bend shows.
    /// `solid` is how far down (a fraction of the height) it stays black, `height` the shape's.
    static func shade(solid: CGFloat, height: CGFloat, look: Look) -> [(alpha: CGFloat, location: CGFloat)] {
        let band = height * (1 - solid)
        // A small card keeps more of the shade, the smaller the more, so its text still reads over a
        // bright page; the rim still clears the most.
        let small = min(1, max(0, (roomy - band) / 60))
        let floor = look.shade + (1 - look.shade) * 0.3 * small
        let start = fadeStart(solid: solid, height: height)
        return [(1, 0)] + (0...steps).map { s in
            let u = CGFloat(s) / CGFloat(steps)
            return (1 - (1 - floor) * fade(u, width: look.fade), start + (1 - start) * u)
        }
    }

    /// Nothing along the black (it's flush with the screen edge), a fine highlight on the glass,
    /// coming in along the same curve as the glass itself.
    static func rim(solid: CGFloat, height: CGFloat, look: Look) -> [(alpha: CGFloat, location: CGFloat)] {
        let start = fadeStart(solid: solid, height: height)
        return [(0, 0)] + (0...steps).map { s in
            let u = CGFloat(s) / CGFloat(steps)
            return (look.rim * fade(u, width: look.fade), start + (1 - start) * u)
        }
    }

    private static let steps = 24

    /// Where the fade begins: a little above the black's end (up to 24 points, a quarter of the glass
    /// on a small card), so it has the room to be gentle. What sits just above is still near black.
    private static func fadeStart(solid: CGFloat, height: CGFloat) -> CGFloat {
        let lead = min(24, height * (1 - solid) * 0.25)
        return max(0, solid - lead / max(height, 1))
    }

    /// How far the shade has cleared at `u` (0 where the fade begins, 1 at the rim): the shoulder of
    /// a bell curve, so it leaves the black flat and its steepness never changes suddenly. Through
    /// fixed points instead, it plunged and then flattened out, and that bend showed as a line.
    private static func fade(_ u: CGFloat, width: CGFloat) -> CGFloat {
        let w2 = width * width
        let tail = exp(-1 / w2)
        return 1 - (exp(-u * u / w2) - tail) / (1 - tail)
    }

    /// How deep the rim bends for `band` points of glass: the level's own on the open notch, scaled
    /// down with a small card, where a full-depth bend reaches past its text and turns the page
    /// behind it upside down. Whole points, so a resizing card doesn't retune the filter every frame.
    static func refraction(band: CGFloat, look: Look) -> (amount: Double, height: Double) {
        let height = min(look.refractionHeight, max(4, (Double(band) * 0.3).rounded()))
        return (look.refraction * height / look.refractionHeight, height)
    }
}

/// The notch's surface with Dynamic Glass on: the black, the shade, the rim and the glass, all
/// Core Animation layers in one view that fills the window, so every frame of the spring moves
/// them together. Being Animatable, SwiftUI hands it the shape as it is at each frame; the view
/// itself never moves or resizes, only its layers' paths do.
private struct NotchSurface: View, Animatable {
    var shape: NotchShape
    var size: CGSize
    /// 0 black, 1 glass; fades with the shape's own spring.
    var glass: Double
    var solid: CGFloat
    let look: DynamicGlass.Look
    /// Open and still: the one time the window may show past the shape (the black notch's shadow).
    let settled: Bool

    var animatableData: AnimatablePair<NotchShape.AnimatableData,
                                       AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<Double, CGFloat>>> {
        get { AnimatablePair(shape.animatableData, AnimatablePair(AnimatablePair(size.width, size.height), AnimatablePair(glass, solid))) }
        set {
            shape.animatableData = newValue.first
            size = CGSize(width: newValue.second.first.first, height: newValue.second.first.second)
            glass = newValue.second.second.first
            solid = newValue.second.second.second
        }
    }

    var body: some View {
        Layers(shape: shape, size: size, glass: glass, solid: solid, look: look, settled: settled)
    }

    private struct Layers: NSViewRepresentable {
        let shape: NotchShape
        let size: CGSize
        let glass: Double
        let solid: CGFloat
        let look: DynamicGlass.Look
        let settled: Bool

        func makeNSView(context: Context) -> SurfaceView { SurfaceView() }

        func updateNSView(_ view: SurfaceView, context: Context) {
            view.state = (shape, size, glass, solid, look, settled)
            view.relayout()
        }
    }

    final class SurfaceView: NSView {
        var state: (shape: NotchShape, size: CGSize, glass: Double, solid: CGFloat, look: DynamicGlass.Look, settled: Bool)?
        private let root = CALayer()
        private let glassLayer = CALayer()
        private let clip = CALayer()
        private let shade = CAGradientLayer()
        private let shadeMask = CAShapeLayer()
        private let rim = CAGradientLayer()
        private let rimMask = CAShapeLayer()
        private let black = CAShapeLayer()
        private var lens: GlassLens.Lens?
        /// Cuts the whole window to the shape these layers draw. The content's own SwiftUI clip
        /// lands on screen a frame apart from Core Animation's layers, so mid-spring it would let
        /// the content show past the black; masked here, content and surface share one edge.
        private let windowMask = CAShapeLayer()

        init() {
            super.init(frame: .zero)
            // Layer-hosting: these layers are ours, in Core Animation's coordinates (y up).
            layer = root
            wantsLayer = true
            if let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type, LiquidGlass.isAvailable {
                let backdrop = layerClass.init()
                backdrop.setValue(true, forKey: "windowServerAware") // samples other apps' windows, not just its own
                backdrop.setValue(UUID().uuidString, forKey: "groupName")
                // The window server pays no attention to masks around a backdrop, but it does clip to
                // rounded corners: the glass sits in a layer cut to the notch's body, its bottom
                // corners the same quarter circles as the notch's.
                clip.masksToBounds = true
                clip.cornerCurve = .circular
                clip.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] // y runs up: the bottom two
                clip.addSublayer(backdrop)
                lens = GlassLens.attach(to: backdrop, blur: 0.4)
                glassLayer.addSublayer(clip)
            }
            shade.mask = shadeMask
            rimMask.fillColor = nil
            rimMask.strokeColor = NSColor.white.cgColor
            rimMask.lineWidth = 1
            rim.mask = rimMask
            black.fillColor = NSColor.black.cgColor
            for sub in [glassLayer, shade, rim, black] { root.addSublayer(sub) }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            relayout()
        }

        /// Glass turned off: the window goes back to unmasked.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let host = window?.contentView?.layer, host.mask === windowMask { host.mask = nil }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            relayout()
        }

        /// Cuts every layer to the notch as it is now: centred, from the top of the window.
        func relayout() {
            guard let (shape, exact, glass, solid, look, settled) = state, bounds.width > 0, exact.width > 0, exact.height > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            let scale = window?.backingScaleFactor ?? 2
            // Whole pixels (the width in pairs, so it stays centred on whole pixels too). The spring's
            // tail creeps a fraction of a pixel for a while after it looks settled; drawn exactly, the
            // lip's last row of pixels flickered between glass and what's behind it, which shows over
            // a hard edge like Mission Control's.
            let size = CGSize(width: max(2 / scale, (exact.width * scale / 2).rounded() * 2 / scale),
                              height: max(1 / scale, (exact.height * scale).rounded() / scale))
            for l in [root, glassLayer, shade, shadeMask, rim, rimMask, black, windowMask] { l.contentsScale = scale }
            let H = bounds.height
            let x0 = (bounds.width - size.width) / 2 // centred, exactly where SwiftUI puts the content

            // SwiftUI's path for the shape (y down), turned over into the layers' y-up space.
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
            let topDown = shape.path(in: CGRect(x: x0, y: 0, width: size.width, height: size.height)).cgPath
            let path = topDown.copy(using: &flip)
            let amount = Float(min(1, max(0, glass)))

            // Settled and black (the teleprompter), the shadow outside the shape is let through.
            if let host = window?.contentView?.layer {
                if settled && amount == 0 {
                    if host.mask === windowMask { host.mask = nil }
                } else {
                    windowMask.frame = host.bounds
                    windowMask.path = host.isGeometryFlipped ? topDown : path
                    if host.mask !== windowMask { host.mask = windowMask }
                }
            }

            black.frame = bounds
            black.path = path
            black.opacity = 1 - amount

            // The shade and rim gradients run down the shape: from the top of the window (1 in
            // unit space, y up) to the shape's bottom edge.
            let bottom = 1 - size.height / H
            let band = size.height * (1 - solid)
            for (layer, mask, stops) in [(shade, shadeMask, DynamicGlass.shade(solid: solid, height: size.height, look: look)),
                                         (rim, rimMask, DynamicGlass.rim(solid: solid, height: size.height, look: look))] {
                layer.frame = bounds
                mask.frame = bounds
                mask.path = path
                layer.startPoint = CGPoint(x: 0.5, y: 1)
                layer.endPoint = CGPoint(x: 0.5, y: bottom)
                layer.colors = stops.map { (layer === rim ? NSColor.white : NSColor.black).withAlphaComponent($0.alpha).cgColor }
                layer.locations = stops.map { NSNumber(value: Double($0.location)) }
            }
            rim.opacity = amount

            // The glass: hidden outright when faded out, so a closed notch isn't sampling the screen.
            glassLayer.frame = bounds
            glassLayer.opacity = amount
            glassLayer.isHidden = amount == 0
            guard let lens, !glassLayer.isHidden else { return }
            let t = shape.topRadius
            let b = max(0, min(shape.bottomRadius, size.height - t, (size.width - 2 * t) / 2))
            // The body between the ears (the ears and the top are black anyway).
            clip.frame = CGRect(x: x0 + t, y: H - size.height, width: max(1, size.width - 2 * t), height: size.height)
            clip.cornerRadius = b
            clip.sublayers?.first?.frame = clip.bounds
            lens.layout(width: clip.bounds.width, height: clip.bounds.height, radius: b)
            lens.tune(look, band: band)
        }
    }
}

enum LiquidGlass {
    /// Core Animation's backdrop layer and the filter Liquid Glass is drawn with.
    static let isAvailable = NSClassFromString("CABackdropLayer") != nil && NSClassFromString("CASDFLayer") != nil
        && NSClassFromString("CASDFElementLayer") != nil && GlassLens.filter("glassBackground") != nil
}

/// Liquid Glass, as the system draws it: what's behind bends at the glass's edges as through a
/// thick lens and stays clear in the middle. It's Core Animation's own glass filter on a backdrop,
/// shaped by a distance field (a rounded rectangle as wide as the notch's body; its top runs past
/// the window, so only the sides and bottom have a rim).
enum GlassLens {
    static func filter(_ type: String) -> NSObject? {
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        return cls.perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject
    }

    final class Lens {
        let element: CALayer
        private let backdrop: CALayer
        private let glass: NSObject
        private var tuned: (amount: Double, height: Double, highlight: Double)?

        init(element: CALayer, backdrop: CALayer, glass: NSObject) {
            self.element = element
            self.backdrop = backdrop
            self.glass = glass
        }

        /// The level's bend (scaled to `band` points of glass) and highlight; the filter is handed
        /// back for them to take effect.
        func tune(_ look: DynamicGlass.Look, band: CGFloat) {
            let bend = DynamicGlass.refraction(band: band, look: look)
            let next = (amount: bend.amount, height: bend.height, highlight: look.highlight)
            guard tuned.map({ $0 != next }) ?? true else { return }
            tuned = next
            glass.setValue(next.amount, forKey: "inputInnerRefractionAmount")
            glass.setValue(next.height, forKey: "inputInnerRefractionHeight")
            glass.setValue(next.highlight, forKey: "inputKeyFillHighlightAmount")
            // A copy: handed the filter it already has, the layer keeps drawing with the old values.
            backdrop.filters = [glass.copy()]
        }

        /// The glass's shape: the clip's own rectangle with the same corners, carried well past the
        /// top so only the sides and bottom have a rim.
        func layout(width: CGFloat, height: CGFloat, radius: CGFloat) {
            element.frame = CGRect(x: 0, y: 0, width: width, height: height + 80)
            element.cornerRadius = radius
            element.superlayer?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        }
    }

    static func attach(to backdrop: CALayer, blur: Double) -> Lens? {
        guard let sdfClass = NSClassFromString("CASDFLayer") as? CALayer.Type,
              let elementClass = NSClassFromString("CASDFElementLayer") as? CALayer.Type,
              let glass = filter("glassBackground") else { return nil }
        // The filter finds its shape by name: the backdrop and its distance field share one.
        backdrop.name = "@0"
        let field = sdfClass.init()
        field.name = "@0"
        let element = elementClass.init()
        field.addSublayer(element)
        backdrop.addSublayer(field)
        let values: [String: Any] = [
            "inputSourceSublayerName": "@0",
            // The system's own bend (−60 over the 20 points inside the rim) until the level tunes it.
            "inputInnerRefractionAmount": -60, "inputInnerRefractionHeight": 20,
            "inputRefractionDistance0": -1, "inputRefractionDistance1": 0,
            // A breath of blur: clear glass, not frosted, with the page behind just soft enough
            // not to fight the notch's own text.
            "inputBlurRadius": blur, "inputBlurOpacity0": 1, "inputBlurOpacity1": 1, "inputBlurOpacity2": 1, "inputBlurOpacity3": 1,
            "inputBlurFillBlurRadius": 0, "inputBlurFillNormalOpacity": 0,
            // The face left as it is: outside the glass's shape the backdrop shows the desktop exactly as
            // it is behind (the window server clips it to nothing), so any tint here would show as a
            // square at the corners. The darkening is the notch's own shade, which is clipped.
            "inputFaceOpacity": 1, "inputFaceColorMatrixWhite": 1, "inputFaceColorMatrixBlack": 0,
            "inputFaceColorMatrixSaturation": 1, "inputFaceColorMatrixMaxLuma": 1, "inputFaceColorMatrixMaxLumaSDR": 1,
            // The light caught along the top of the rim.
            "inputKeyFillHighlightHeight": 0.5, "inputKeyFillHighlightAngle": Double.pi / 2, "inputKeyFillHighlightSpread": 1.309,
            "inputKeyFillHighlightSpreadSDR": 1.309, "inputKeyFillHighlightAmount": 0.4, "inputKeyFillHighlightEffectOffset": -0.5,
            "inputKeyFillHighlightColorBias": -0.25,
            "inputMaxHeadroom": 1.2, "inputClamp": 1, "inputSDRGradientDistance0": 1, "inputSDRGradientDistance1": 1,
            "inputBleedDistance0": 1,
        ]
        for (key, value) in values { glass.setValue(value, forKey: key) }
        backdrop.filters = [glass]
        return Lens(element: element, backdrop: backdrop, glass: glass)
    }
}
