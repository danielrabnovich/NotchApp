import AppKit
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case ask, home, shelf, tasks, timer, mixer, controls, stats
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house.fill"
        case .shelf: "tray.full.fill"
        case .tasks: "checklist"
        case .timer: "timer"
        case .mixer: "slider.vertical.3"
        case .stats: "gauge.with.dots.needle.50percent"
        case .ask: "sparkle.magnifyingglass"
        case .controls: "switch.2"
        }
    }
}

/// What the collapsed notch is currently showing beside the hardware notch.
enum CollapsedActivity: Equatable {
    case none
    case music
    case tasks
    case timer
    case working
    case peek(SneakPeek.Kind)
}

/// Per-screen notch state.
@MainActor
final class NotchViewModel: ObservableObject {
    let notchSize: CGSize
    let hasPhysicalNotch: Bool

    @Published var isOpen = false
    /// True once the open animation has finished (used for effects too costly to animate).
    @Published var isSettled = false
    @Published var isHovering = false
    @Published var tab: NotchTab = AppSettings.shared.assistantEnabled ? .ask : .home

    /// Something is being dragged over the notch from another app; show the drop bins.
    @Published var isDragActive = false
    @Published var dragPreview: DragPreview?

    /// Live horizontal offset while two-finger swiping between tabs.
    /// Swipe state lives in its own object: it changes every frame of a swipe, and only the
    /// pager and tab indicator should re-render for it (not every page that observes this model).
    let pager = PagerState()
    var pageOffset: CGFloat {
        get { pager.offset }
        set { pager.offset = newValue }
    }
    var isSwiping: Bool {
        get { pager.isSwiping }
        set { pager.isSwiping = newValue }
    }
    /// A tab change is still animating into place; keep the neighbouring pages rendered.
    var isSettling: Bool {
        get { pager.isSettling }
        set { pager.isSettling = newValue }
    }
    var pageWidth: CGFloat {
        get { pager.width }
        set { pager.width = newValue }
    }

    /// A text field inside the notch has keyboard focus – don't auto-close.
    @Published var isEditing = false

    /// Makes the notch window key so a text field can take typing (set by the window controller).
    var takeKeyFocus: () -> Void = {}

    /// Brief or nudge the app opened by itself; stays until acted on.
    @Published var overlay: NotchOverlay?
    /// The camera mirror is showing in place of the tabs.
    @Published var mirror = false

    /// Areas (in hosting-view coordinates, top-left origin) that scroll horizontally on their own,
    /// keyed by whoever registered them.
    var horizontalScrollRegions: [String: CGRect] = [:]

    /// Corner radii for the black shape (top flare / bottom rounding).
    var topRadius: CGFloat { isOpen ? 14 : 6 }
    var bottomRadius: CGFloat { isOpen ? 26 : (hasPhysicalNotch ? 10 : 12) }

    init(notchSize: CGSize, hasPhysicalNotch: Bool) {
        self.notchSize = notchSize
        self.hasPhysicalNotch = hasPhysicalNotch
    }

    /// The Ask tab grows taller once it has results so they never feel cramped.
    var openSize: CGSize {
        let assistant = AssistantStore.shared
        let roomy = tab == .ask && (assistant.current != nil || assistant.suggesting) && overlay == nil && !isDragActive
        return CGSize(width: openWidth, height: notchSize.height + (roomy || mirror ? 258 : 168))
    }

    /// Largest size the open notch can reach (sizes the window).
    var maxOpenSize: CGSize { CGSize(width: openWidth, height: notchSize.height + 258) }

    /// Wide enough for every tab button beside the notch.
    private var openWidth: CGFloat { max(680, notchSize.width + 460) }

    var tabs: [NotchTab] {
        let s = AppSettings.shared
        var t: [NotchTab] = []
        if s.assistantEnabled { t.append(.ask) }
        if s.musicEnabled || s.calendarEnabled { t.append(.home) }
        if s.shelfEnabled { t.append(.shelf) }
        if s.tasksEnabled { t.append(.tasks) }
        if s.timerEnabled { t.append(.timer) }
        if s.mixerEnabled { t.append(.mixer) }
        if s.controlsEnabled { t.append(.controls) }
        if s.statsEnabled { t.append(.stats) }
        return t
    }

    var tabIndex: Int { tabs.firstIndex(of: tab) ?? 0 }

    /// Number shown beside the notch, if any.
    var taskBadgeCount: Int? {
        let s = AppSettings.shared
        let n = TaskStore.shared.openCount
        return s.tasksEnabled && s.showTaskCount && n > 0 ? n : nil
    }

    var activity: CollapsedActivity {
        if let peek = ActivityCenter.shared.peek { return .peek(peek.kind) }
        let s = AppSettings.shared
        let media = MediaController.shared
        if s.timerEnabled, s.timerLiveActivity, TimerStore.shared.isActive { return .timer }
        if s.assistantEnabled, AssistantStore.shared.runningCount > 0 { return .working }
        if s.musicEnabled, s.musicLiveActivity, media.hasTrack, media.isPlaying { return .music }
        if taskBadgeCount != nil { return .tasks }
        return .none
    }

    /// Width added on each side of the hardware notch for live activities.
    var sideWidth: CGFloat {
        switch activity {
        case .none: 0
        case .music: notchSize.height + 6 + (taskBadgeCount != nil ? 22 : 0)
        case .tasks: notchSize.height
        case .timer: 54
        case .working: notchSize.height + 4
        case .peek(let kind): kind.sideWidth(notchHeight: notchSize.height)
        }
    }

    var collapsedSize: CGSize {
        var w = notchSize.width + 2 * sideWidth
        var h = notchSize.height
        if case .peek(let kind) = activity, kind.hasSubtitle { h += 26 }
        if isHovering, !isOpen {
            w += 14
            h += 3
        }
        return CGSize(width: w, height: h)
    }

    /// Size of the black body (without the top corner flares).
    var bodySize: CGSize { isOpen ? openSize : collapsedSize }

    /// Size of the full shape including the top flares.
    var shapeSize: CGSize { CGSize(width: bodySize.width + 2 * topRadius, height: bodySize.height) }

    /// The search bar should take the keyboard when the notch opens (on hover too, unless that's
    /// turned off in Settings).
    @Published var wantsKeyboard = false

    func open(tab: NotchTab? = nil, takeKeyboard: Bool = true) {
        if takeKeyboard { wantsKeyboard = true }
        // Search is the default view each time the notch opens.
        let target = tab ?? (tabs.contains(.ask) ? .ask : nil)
        if let target, tabs.contains(target) { self.tab = target }
        guard !isOpen else { return }
        // Take the keyboard as the open begins (before the content is built), so typing can start
        // straight away; doing it after the animation re-rendered the whole panel and dropped frames.
        if wantsKeyboard { takeKeyFocus() }
        withAnimation(AppSettings.shared.openAnimation, completionCriteria: .logicallyComplete) {
            isOpen = true
        } completion: { [weak self] in
            guard let self, self.isOpen else { return }
            self.isSettled = true
            self.prepareNeighbors()
        }
    }

    func close() {
        guard isOpen else { return }
        isSettled = false
        wantsKeyboard = false
        pager.neighborsReady = false
        withAnimation(AppSettings.shared.closeAnimation) {
            isOpen = false
            isDragActive = false
            isEditing = false
            pageOffset = 0
            overlay = nil
            mirror = false
        }
    }

    func select(_ tab: NotchTab) {
        wantsKeyboard = true
        guard tab != self.tab else { return }
        slide(to: tab, animation: .spring(response: 0.42, dampingFraction: 0.84))
    }

    /// Moves to a tab. The page row's resting position switches instantly (it's real layout, and
    /// animating it would re-frame every AppKit control inside on each frame); the visible slide is
    /// the render-only swipe offset, set so nothing jumps and then animated back to zero.
    func slide(to tab: NotchTab, animation: Animation) {
        let old = tabIndex
        let new = tabs.firstIndex(of: tab) ?? old
        pager.fromIndex = old
        isSettling = true
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            self.tab = tab
            pageOffset += CGFloat(new - old) * pageWidth
            isSwiping = false
        }
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            pageOffset = 0
        } completion: { [weak self] in
            self?.isSettling = false
            FrameProbe.mark("settled")
            self?.prepareNeighbors()
        }
    }

    private func prepareNeighbors() {
        pager.neighborsReady = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isOpen, !self.isSettling, !self.isSwiping else { return }
            FrameProbe.mark("neighbors")
            self.pager.neighborsReady = true
        }
    }
}

@MainActor
final class PagerState: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var isSwiping = false
    @Published var isSettling = false
    /// The tab a change started from, kept rendered until the slide settles.
    var fromIndex: Int?
    /// Neighbouring tabs are built while nothing is moving, so a swipe never has to build them
    /// on its first frame (a visible hitch); building them mid-animation slowed the opening.
    @Published var neighborsReady = false
    var width: CGFloat = 600
}
