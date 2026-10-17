import SwiftUI

struct AlbumArtView: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.16)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Bouncing bars that suggest the music's energy, tinted with the accent colour.
/// Bars that move with the music: real levels from AudioSpectrum (bass on the left, treble on the
/// right) when it's listening, or a gentle stand-in animation when it can't (no permission yet).
struct AudioVisualizer: View {
    let color: Color
    let isPlaying: Bool
    var barCount = 4

    @ObservedObject private var spectrum = AudioSpectrum.shared

    var body: some View {
        VisualizerBars(color: NSColor(color), isPlaying: isPlaying, barCount: barCount,
                       levels: spectrum.isLive ? bandLevels : nil)
            .onAppear { AudioSpectrum.shared.viewerAppeared() }
            .onDisappear { AudioSpectrum.shared.viewerDisappeared() }
    }

    /// The live levels spread across the bars, bass to treble.
    private var bandLevels: [CGFloat] {
        let bands = spectrum.levels
        guard !bands.isEmpty else { return [] }
        return (0..<barCount).map { bar in
            let band = min(bands.count - 1, Int((Double(bar) + 0.5) * Double(bands.count) / Double(barCount)))
            return 0.15 + 0.85 * bands[band]
        }
    }
}

/// The bars as Core Animation layers. The stand-in bounce (no permission to listen) is a looping
/// layer animation that runs in the window server, costing the app nothing per frame; live levels
/// just set each bar's scale. Drawn with SwiftUI, the bars re-rendered the closed notch 30–120
/// times a second for as long as music played.
private struct VisualizerBars: NSViewRepresentable {
    let color: NSColor
    let isPlaying: Bool
    let barCount: Int
    let levels: [CGFloat]?

    func makeNSView(context: Context) -> BarsView { BarsView() }

    func updateNSView(_ view: BarsView, context: Context) {
        view.update(color: color, playing: isPlaying, count: barCount, levels: levels)
    }

    final class BarsView: NSView {
        private var bars: [CALayer] = []
        private var mode: String = ""

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            placeBars()
        }

        func update(color: NSColor, playing: Bool, count: Int, levels: [CGFloat]?) {
            if bars.count != count {
                bars.forEach { $0.removeFromSuperlayer() }
                bars = (0..<count).map { _ in
                    let bar = CALayer()
                    bar.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
                    layer?.addSublayer(bar)
                    return bar
                }
                mode = ""
                placeBars()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bars.forEach { $0.backgroundColor = color.cgColor }
            let next = !playing ? "still" : levels == nil ? "bounce" : "live"
            if next != mode {
                mode = next
                bars.forEach { $0.removeAllAnimations() }
                if next == "still" { bars.forEach { $0.transform = scale(0.18) } }
                if next == "bounce" { startBounce() }
            }
            if next == "live", let levels {
                for (bar, level) in zip(bars, levels) { bar.transform = scale(level) }
            }
            CATransaction.commit()
        }

        private func placeBars() {
            guard !bars.isEmpty else { return }
            let spacing: CGFloat = 2
            let w = (bounds.width - spacing * CGFloat(bars.count - 1)) / CGFloat(bars.count)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, bar) in bars.enumerated() {
                let saved = bar.transform
                bar.transform = CATransform3DIdentity
                bar.frame = CGRect(x: CGFloat(i) * (w + spacing), y: 0, width: w, height: bounds.height)
                bar.cornerRadius = w / 2
                bar.transform = saved
            }
            CATransaction.commit()
        }

        private func scale(_ y: CGFloat) -> CATransform3D { CATransform3DMakeScale(1, max(0.15, min(1, y)), 1) }

        /// Each bar on its own slow loop of heights, so together they never visibly repeat.
        private func startBounce() {
            let shapes: [[CGFloat]] = [[0.45, 0.95, 0.35, 0.8, 0.55, 0.45], [0.8, 0.4, 1, 0.5, 0.7, 0.8],
                                       [0.55, 0.85, 0.45, 0.65, 0.95, 0.55], [0.7, 0.35, 0.75, 0.95, 0.4, 0.7]]
            for (i, bar) in bars.enumerated() {
                let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
                a.values = shapes[i % shapes.count]
                a.duration = 1.5 + Double(i) * 0.23
                a.calculationMode = .cubic
                a.repeatCount = .infinity
                a.timeOffset = Double(i) * 0.37
                bar.add(a, forKey: "bounce")
            }
        }
    }
}

/// Thin progress bar used by the volume / brightness HUD.
struct LevelBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                    .animation(.spring(response: 0.25, dampingFraction: 0.85), value: value)
            }
        }
        .frame(height: 5)
    }
}

struct BatteryIcon: View {
    let level: Int
    let charging: Bool
    var lowPower = false
    var animated = false

    @State private var fill: CGFloat = 0

    private var color: Color {
        if lowPower { return .yellow }
        if charging { return .green }
        if level <= 20 { return .red }
        return .white
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, 19 * fill)) // the whole inside of the outline at 100%
                    .padding(1.5)
            }
            .frame(width: 22, height: 11)
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
        .onAppear {
            let target = CGFloat(level) / 100
            if animated {
                fill = 0
                withAnimation(.easeOut(duration: 1.1).delay(0.15)) { fill = target }
            } else {
                fill = target
            }
        }
        .onChange(of: level) { _, new in
            withAnimation(.easeOut(duration: 0.4)) { fill = CGFloat(new) / 100 }
        }
    }
}

/// The battery as on recent iPhones and iPads: a squat body with the charge as a fill and the
/// number inside it in heavy type, green while charging, yellow in Low Power Mode, red when low,
/// and the bolt beside it while plugged in.
struct BatteryGlyph: View {
    let level: Int
    let charging: Bool
    var pluggedIn = false
    var lowPower = false
    /// Height of the body; everything else scales from it.
    var height: CGFloat = 13.5
    @Environment(\.displayScale) private var displayScale

    /// Body plus nub. The bolt sits inside while plugged in, so the width never changes.
    static func width(height: CGFloat = 13.5, plugged: Bool = false) -> CGFloat {
        bodyWidth(height) + 1 + nubWidth(height)
    }
    private static func bodyWidth(_ h: CGFloat) -> CGFloat { (h * 1.95).rounded() }
    private static func nubWidth(_ h: CGFloat) -> CGFloat { max(1.5, h * 0.11) }

    /// On power: charging, or plugged in and holding the charge (macOS then says "not charging",
    /// but iPhone and iPad still show it green with the bolt).
    private var onPower: Bool { charging || pluggedIn }
    /// Critically low and not on power: the whole battery tints red, not just the sliver of fill.
    private var critical: Bool { level <= 10 && !onPower }

    private var fillColor: Color {
        if lowPower { return Color(red: 1, green: 0.84, blue: 0.04) }
        if onPower { return Color(red: 0.2, green: 0.84, blue: 0.35) }
        if level <= 20 { return Color(red: 1, green: 0.27, blue: 0.23) }
        return .white
    }

    /// White on the green and red fills (as on iPhone), and when critically low; black on white
    /// and on Low Power yellow.
    private var textColor: Color {
        if critical { return .white }
        if lowPower { return .black.opacity(0.9) }
        if onPower || level <= 20 { return .white }
        return .black.opacity(0.9)
    }

    private var trackColor: Color {
        critical ? Color(red: 1, green: 0.27, blue: 0.23).opacity(0.45) : .white.opacity(0.35)
    }

    var body: some View {
        let w = Self.bodyWidth(height)
        let shape = RoundedRectangle(cornerRadius: height * 0.34, style: .continuous)
        let fraction = CGFloat(min(max(level, 0), 100)) / 100
        // On power the bolt shares the inside with the number: tucked right up against it, so the
        // number can stay nearly full size.
        let numberSize = height * (onPower ? (level >= 100 ? 0.64 : 0.78) : (level >= 100 ? 0.68 : 0.82))
        // Digits have no descenders, so centring the line box leaves them high by an amount that
        // varies with size. Centre on the digits instead (half the cap height above the baseline),
        // with their offset from the top in whole pixels: otherwise, on a glance that lands on a
        // fraction of a pixel, the text and the body round different ways and the number sits high.
        let capHeight = NSFont.systemFont(ofSize: numberSize, weight: .bold).capHeight
        let digitMiddle: (ViewDimensions) -> CGFloat = { d in
            let middle = d[.firstTextBaseline] - capHeight / 2
            let top = ((height / 2 - middle) * displayScale).rounded() / displayScale
            return height / 2 - top
        }
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                shape.fill(trackColor)
                Rectangle()
                    .fill(fillColor)
                    .frame(width: w * fraction)
                HStack(alignment: .firstTextBaseline, spacing: -0.5) {
                    Text("\(level)")
                        .font(.system(size: numberSize, weight: .bold))
                        .tracking(level >= 100 ? -0.4 : -0.2)
                    if onPower {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: height * 0.5, weight: .black))
                            // Centred on the digits, not hanging below them as it would inline
                            .alignmentGuide(.firstTextBaseline) { d in
                                ((d.height + capHeight) / 2 * displayScale).rounded() / displayScale
                            }
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .foregroundStyle(textColor)
                .lineLimit(1)
                .fixedSize()
                .frame(width: w)
                .alignmentGuide(VerticalAlignment.center, computeValue: digitMiddle)
            }
            .frame(width: w, height: height)
            .clipShape(shape)
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 1.5, topTrailingRadius: 1.5, style: .continuous)
                .fill(level >= 99 ? fillColor : trackColor)
                .frame(width: Self.nubWidth(height), height: height * 0.36)
        }
        .animation(.easeOut(duration: 0.4), value: level)
        .animation(.easeOut(duration: 0.25), value: fillColor)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: onPower)
        .accessibilityElement()
        .accessibilityLabel("Battery \(level)%\(charging ? ", charging" : pluggedIn ? ", plugged in" : "")\(lowPower ? ", Low Power Mode" : "")")
    }
}

/// Circular icon button with a soft hover highlight.
struct NotchIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, size: size)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.22 : hovering ? 0.12 : 0)))
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    /// Lets two-finger horizontal scrolls over this view scroll it instead of switching tabs.
    func horizontalScrollRegion(_ id: String, in viewModel: NotchViewModel, active: Bool = true) -> some View {
        modifier(HorizontalScrollRegion(id: id, viewModel: viewModel, active: active))
    }
}

/// Every page is laid out in the same place (the pager moves them), so a region is kept under
/// its page's name and only counts while that page is the one showing.
private struct HorizontalScrollRegion: ViewModifier {
    let id: String
    let viewModel: NotchViewModel
    let active: Bool
    @Environment(\.notchPage) private var page

    func body(content: Content) -> some View {
        let key = "\(page?.rawValue ?? "-"):\(id)"
        return content.background(GeometryReader { geo in
            let frame = geo.frame(in: .global)
            Color.clear
                .onAppear { viewModel.horizontalScrollRegions[key] = active ? frame : nil }
                .onChange(of: frame) { _, f in viewModel.horizontalScrollRegions[key] = active ? f : nil }
                .onChange(of: active) { _, a in viewModel.horizontalScrollRegions[key] = a ? frame : nil }
                .onDisappear { viewModel.horizontalScrollRegions[key] = nil }
        })
    }
}

/// Title-style switcher between the panes that share a tab ("Tasks · Notes", "Shelf · Downloads").
extension View {
    /// For an item in a horizontal scroll view: it fades out over the last stretch before either
    /// edge, so a row that scrolls reads as continuing instead of being cut off square. (Each item
    /// is masked by where it sits: a mask on the scroll view itself doesn't reach into AppKit's.)
    func scrollEdgeFade(_ fade: CGFloat = 28) -> some View {
        mask {
            GeometryReader { g in
                let frame = g.frame(in: .scrollView(axis: .horizontal))
                let width = g.bounds(of: .scrollView(axis: .horizontal))?.width ?? .infinity
                let w = max(g.size.width, 1)
                // The container's edges in the item's own coordinates, as fractions of its width.
                let right = (width - frame.minX) / w
                let left = -frame.minX / w
                let f = fade / w
                LinearGradient(stops: [
                    .init(color: frame.minX < 0 ? .clear : .black, location: 0),
                    .init(color: frame.minX < 0 ? .clear : .black, location: min(1, max(0, left))),
                    .init(color: .black, location: min(1, max(0, left + (frame.minX < 0 ? f : 0)))),
                    .init(color: .black, location: min(1, max(0, right - (frame.maxX > width ? f : 0)))),
                    .init(color: frame.maxX > width ? .clear : .black, location: min(1, max(0, right))),
                    .init(color: frame.maxX > width ? .clear : .black, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
        }
    }
}

/// A right-click menu item with its symbol (macOS shows them beside each command).
struct MenuItem: View {
    let title: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void

    init(_ title: String, _ icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) { Label(title, systemImage: icon) }
    }
}

/// "Open With" for files: each app with its own icon, the default first.
struct OpenWithMenu: View {
    let urls: [URL]

    /// Asked of Launch Services once per kind of file: menus are rebuilt each time their card
    /// redraws (a hover), and the lookup isn't quick.
    @MainActor private static var appCache: [String: (apps: [URL], at: Date)] = [:]
    @MainActor private static var iconCache: [URL: NSImage] = [:]

    @MainActor static func apps(toOpen url: URL) -> [URL] {
        let key = url.hasDirectoryPath ? "/" : url.pathExtension.lowercased()
        if let hit = appCache[key], Date().timeIntervalSince(hit.at) < 300 { return hit.apps }
        let apps = Array(NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(14))
        appCache[key] = (apps, Date())
        return apps
    }

    @MainActor static func icon(_ app: URL) -> NSImage {
        if let hit = iconCache[app] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        iconCache[app] = icon
        return icon
    }

    var body: some View {
        let apps = urls.first.map(Self.apps(toOpen:)) ?? []
        if !apps.isEmpty {
            Menu {
                ForEach(Array(apps.prefix(14)), id: \.self) { app in
                    Button {
                        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    } label: {
                        Label {
                            Text(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
                        } icon: {
                            Image(nsImage: Self.icon(app))
                        }
                    }
                }
                Divider()
                MenuItem("Other…", "ellipsis.circle") {
                    let panel = NSOpenPanel()
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowedContentTypes = [.application]
                    panel.prompt = "Open"
                    NSApp.activate(ignoringOtherApps: true)
                    if panel.runModal() == .OK, let app = panel.url {
                        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            } label: {
                Label("Open With", systemImage: "arrow.up.forward.app")
            }
        }
    }
}

extension View {
    /// A tab's top row (its panes, a title, a field or a button on the right): one height on every
    /// tab, so the titles sit on the same line as you swipe between them.
    func notchHeaderRow() -> some View { frame(height: 26) }
}

struct PaneSwitcher<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(Motion.small.animation) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.35))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }
}

/// An app's Finder icon from its bundle path, or a generic gear for bare processes.
struct AppIcon: View {
    let bundlePath: String?
    var size: CGFloat = 12
    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let bundlePath {
            Image(nsImage: Self.icon(for: bundlePath)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: size * 0.66))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: size, height: size)
        }
    }

    private static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

/// Real system and app icons (AirDrop, Tailscale) rather than look-alike symbols.
@MainActor
enum SystemIcons {
    static let airDrop = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
    static let tailscale: NSImage? = FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
        ? NSWorkspace.shared.icon(forFile: "/Applications/Tailscale.app") : nil
}

extension View {
    /// The shared raised surface: a top-lit fill with a hairline edge that catches the light,
    /// brighter while `active` (focused, hovered).
    func notchSurface<S: InsettableShape>(_ shape: S, active: Bool = false) -> some View {
        background(shape.fill(LinearGradient(colors: [.white.opacity(active ? 0.13 : 0.09), .white.opacity(active ? 0.08 : 0.05)],
                                             startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(active ? 0.26 : 0.14), .white.opacity(active ? 0.09 : 0.04)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

/// A small keyboard key, for shortcut hints ("↩", "⌃⌥G").
struct KeyCap: View {
    let text: String
    var onAccent = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(onAccent ? 0.95 : 0.55))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(.white.opacity(onAccent ? 0.22 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(.white.opacity(onAccent ? 0 : 0.08), lineWidth: 1))
    }
}

/// Rounded text button: solid white when primary, a soft fill otherwise.
struct NotchPillButtonStyle: ButtonStyle {
    var primary = false
    var height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, primary: primary, height: height)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let primary: Bool
        let height: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: primary ? .semibold : .medium))
                .foregroundStyle(primary ? .black : .white.opacity(0.88))
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: height)
                .background(Capsule().fill(primary ? .white.opacity(hovering ? 1 : 0.92) : .white.opacity(hovering ? 0.16 : 0.1)))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

/// Nudges a view onto whole pixels. Glances can land on quarter points (a centred 13.5 pt item),
/// which leaves fine detail (a 2 pt dot, a 1 pt rule) shaded unevenly; this moves it by less
/// than a pixel so it's drawn crisp. Measured outside the nudge, so it doesn't chase itself.
struct PixelSnap: ViewModifier {
    @Environment(\.displayScale) private var scale
    @State private var nudge: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .offset(nudge)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
                let snap = { (v: CGFloat) in (v * scale).rounded() / scale - v }
                let next = CGSize(width: snap(origin.x), height: snap(origin.y))
                if next != nudge { nudge = next }
            }
    }
}

extension View {
    func pixelSnapped() -> some View { modifier(PixelSnap()) }
}

extension View {
    /// Digits that roll to their new value, as the Dynamic Island's do. For readings that change
    /// now and then (a percent, a clock); ones that tick every second change in place, to stay calm.
    func rollingDigits<V: Equatable>(_ value: V) -> some View {
        contentTransition(.numericText()).animation(.snappy(duration: 0.35), value: value)
    }
}

/// Keys for one tab's content: only while this notch's window has the keyboard and `tab` is
/// showing (no overlay over it), and only while the view it's on is on screen. Unhandled keys
/// carry on as usual.
struct TabKeyboard: ViewModifier {
    @ObservedObject var viewModel: NotchViewModel
    let tab: NotchTab
    /// Modifiers held right now (the Shelf's quick paste numbers show while they're held).
    @Binding var held: UInt32
    /// Returns whether it took the key.
    let handle: (NSEvent) -> Bool
    @State private var monitor: Any?

    init(viewModel: NotchViewModel, tab: NotchTab, held: Binding<UInt32> = .constant(0), handle: @escaping (NSEvent) -> Bool) {
        self.viewModel = viewModel
        self.tab = tab
        self._held = held
        self.handle = handle
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                    MainActor.assumeIsolated { route(event) ? nil : event }
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                held = 0
            }
    }

    private func route(_ event: NSEvent) -> Bool {
        guard event.window is NotchPanel, viewModel.isOpen, viewModel.tab == tab, viewModel.overlay == nil, !viewModel.mirror else { return false }
        if event.type == .flagsChanged {
            held = ShelfKey.carbon(event.modifierFlags)
            return false
        }
        return handle(event)
    }
}
