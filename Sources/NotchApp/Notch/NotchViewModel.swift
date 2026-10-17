import AppKit
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case ask, home, shelf, tasks, timer, mixer, controls, stats, tools, agents
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
        case .tools: "wrench.and.screwdriver.fill"
        case .agents: "sparkles.rectangle.stack.fill"
        }
    }

    var title: String {
        switch self {
        case .ask: "Search"
        case .home: "Home"
        case .shelf: "Shelf"
        case .tasks: "Tasks"
        case .timer: "Timer"
        case .mixer: "Mixer"
        case .controls: "Controls"
        case .stats: "Stats"
        case .tools: "Tools"
        case .agents: "Agents"
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
    /// A speed test is running: a gauge and the live speed.
    case speedTest
    /// A yt-dlp download: a progress ring and percent.
    case videoDownload
    /// The live activities pinned in Settings.
    case live
    case peek(SneakPeek.Kind)
}

/// What opened the notch, which decides what closes it.
enum OpenReason {
    /// The pointer rested on the notch: leaving it closes it again.
    case hover
    /// A click on the notch.
    case click
    /// A keyboard shortcut: stays open until Esc, the shortcut again, or a click elsewhere.
    case keyboard
    /// The app itself (a dropped file, a brief, a notification's button).
    case system
}

/// Per-screen notch state.
@MainActor
final class NotchViewModel: ObservableObject {
    let notchSize: CGSize
    let hasPhysicalNotch: Bool

    @Published var isOpen = false
    /// True once the open animation has finished (used for effects too costly to animate).
    @Published var isSettled = false
    @Published var isHovering = false {
        // The pointer on its way in: read the app in front now, so its actions are up as search opens.
        didSet {
            if isHovering, !oldValue, !isOpen { AppActions.shared.prepare() }
            if !isHovering { endGlancePeek() }
        }
    }
    @Published var tab: NotchTab = AppSettings.shared.assistantEnabled ? .ask : .home

    /// Something is being dragged over the notch from another app; show the drop bins.
    @Published var isDragActive = false
    @Published var dragPreview: DragPreview?

    /// The pages and the tab pill, moved by Core Animation (see `PagerState`). Kept out of the
    /// published state: a swipe changes it every frame, and nothing in SwiftUI should re-render for it.
    let pager = PagerState()
    var isSwiping: Bool { pager.isSwiping }
    /// A tab change is still animating into place.
    var isSettling: Bool { pager.isSettling }
    var pageWidth: CGFloat { pager.width }
    /// The hosting view the pages are drawn in (their own coordinate space, for scroll regions).
    weak var pagesHost: NSView?

    /// A text field inside the notch has keyboard focus – don't auto-close.
    @Published var isEditing = false

    /// Makes the notch window key so a text field can take typing (set by the window controller).
    var takeKeyFocus: () -> Void = {}

    /// What was typed after the notch took the keyboard but before the search bar had it (it
    /// waits for the opening animation, where taking focus cost a dropped frame). The search bar
    /// takes it as it focuses.
    @Published var typeAhead = ""
    /// Deletes pressed before the field had the keyboard.
    @Published var typeAheadDelete = 0

    /// Keeps a key press for the search bar, if it's on its way to taking the keyboard.
    func keepTypeAhead(_ event: NSEvent) -> Bool {
        guard isOpen, wantsKeyboard, tab == .ask, overlay == nil, !mirror else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .function]) else { return false }
        if event.keyCode == 51 { // delete: the typed-ahead text is already in the field
            typeAheadDelete += 1
            return true
        }
        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        typeAhead += chars
        return true
    }

    /// Brief or nudge the app opened by itself; stays until acted on.
    @Published var overlay: NotchOverlay?
    /// The camera mirror is showing in place of the tabs.
    @Published var mirror = false

    /// Areas (in hosting-view coordinates, top-left origin) that scroll horizontally on their own,
    /// keyed by whoever registered them.
    var horizontalScrollRegions: [String: CGRect] = [:]

    /// Corner radii for the black shape (top flare / bottom rounding).
    var topRadius: CGFloat { isOpen ? 14 : 6 }
    var bottomRadius: CGFloat {
        if isOpen { return 26 }
        // A Banner hanging under the notch reads as a card.
        if ActivityCenter.shared.banner != nil { return 20 }
        return hasPhysicalNotch ? 10 : 12
    }

    /// Most room each side's Glances may take: half the menu bar beside the notch, so the
    /// frontmost app's menus and the status icons stay reachable.
    let glanceBudget: CGFloat

    init(notchSize: CGSize, hasPhysicalNotch: Bool, screenWidth: CGFloat) {
        self.notchSize = notchSize
        self.hasPhysicalNotch = hasPhysicalNotch
        glanceBudget = max(120, (screenWidth - notchSize.width) / 4)
    }

    /// One side's Glances as they fit this screen.
    func glanceRow(_ side: LiveSlot.Side) -> GlanceRow {
        LiveActivities.shared.row(side, notchHeight: notchSize.height, budget: glanceBudget)
    }

    /// The sides hold Glances, which are clicked rather than hovered: resting on them doesn't
    /// open the notch (hovering the notch itself still does).
    var wingsAreInteractive: Bool { !isOpen && activity == .live }

    /// The Ask tab grows taller once it has results so they never feel cramped.
    var openSize: CGSize {
        let assistant = AssistantStore.shared
        let onAsk = tab == .ask && overlay == nil && !isDragActive && !mirror
        if onAsk, assistant.current == nil, assistant.suggesting {
            // Fit the results-as-you-type list: content insets (8 + 16), the compact bar with its
            // glow room (7 + 38), the gap (6), the list's padding (2 × 5) and its rows.
            let list = 85 + CGFloat(assistant.suggestionRows) * 30
            return CGSize(width: openWidth, height: notchSize.height + min(258, max(168, list)))
        }
        let roomy = onAsk && (assistant.current != nil || RambleStore.shared.active)
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
        if s.toolsEnabled { t.append(.tools) }
        if s.agentsEnabled { t.append(.agents) }
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
        return restingActivity
    }

    /// What the collapsed notch shows when no Flash is up.
    private var restingActivity: CollapsedActivity {
        let s = AppSettings.shared
        let media = MediaController.shared
        // The pinned layout holds; a running timer joins it rather than replacing it.
        if s.speedTestLiveActivity, SpeedTest.shared.phase.isRunning { return .speedTest }
        // With the Progress Glance on, a download shows among the Glances; without it, as its own ring.
        if s.downloadLiveActivity, !s.progressGlance, VideoDownloader.shared.current != nil { return .videoDownload }
        if !LiveActivities.shared.isEmpty { return .live }
        if s.downloadLiveActivity, VideoDownloader.shared.current != nil { return .videoDownload }
        if s.timerEnabled, s.timerLiveActivity, TimerStore.shared.isActive { return .timer }
        if s.assistantEnabled, AssistantStore.shared.runningCount > 0 { return .working }
        if s.musicEnabled, s.musicLiveActivity, media.hasTrack, media.isPlaying { return .music }
        if taskBadgeCount != nil { return .tasks }
        return .none
    }

    /// Width added on each side of the hardware notch for live activities.
    var sideWidth: CGFloat {
        // A Flash takes over the wings it finds, never narrower: the notch doesn't pull in for a
        // volume change and spring back out after it.
        if case .peek(let kind) = activity { return max(kind.sideWidth(notchHeight: notchSize.height), width(of: restingActivity)) }
        return width(of: activity)
    }

    private func width(of activity: CollapsedActivity) -> CGFloat {
        switch activity {
        case .none: 0
        case .music: notchSize.height + 6 + (taskBadgeCount != nil ? 22 : 0)
        case .tasks: notchSize.height
        case .timer: 54
        case .working: notchSize.height + 4
        case .speedTest: 62
        case .videoDownload: 54
        case .live: LiveActivities.shared.sideWidth(notchHeight: notchSize.height, budget: glanceBudget)
        case .peek(let kind): kind.sideWidth(notchHeight: notchSize.height)
        }
    }

    /// Quick drops wait in a stack hanging under the collapsed notch.
    var showsStack: Bool {
        let s = AppSettings.shared
        return s.shelfEnabled && s.shelfStack && !ShelfStore.shared.stack.isEmpty
    }

    /// Height of the stack row under the collapsed notch.
    static let stackHeight: CGFloat = 32

    /// The pointer is on the stack: it fans out into its files (set by the window controller).
    @Published var stackHovered = false

    /// The Glance the pointer is resting on, whose details hang under the notch (instead of a tooltip).
    @Published private(set) var peekedGlance: LiveItem?
    /// The peeked Glance's middle (in the collapsed notch's coordinates), for the card's caret.
    @Published private(set) var peekAnchorX: CGFloat?
    /// Where each Glance's middle is (in the collapsed notch's coordinates), as laid out.
    var glanceMidX: [LiveItem: CGFloat] = [:]
    private var peekWork: DispatchWorkItem?

    /// The pointer came onto or left a Glance. A peek waits for it to rest a moment; once one is
    /// up, moving along to the next Glance swaps it straight away.
    func hoverGlance(_ item: LiveItem, _ inside: Bool) {
        peekWork?.cancel()
        let anchorX = glanceMidX[item]
        let work: DispatchWorkItem
        if inside {
            work = DispatchWorkItem { [weak self] in
                guard let self, !self.isOpen, ActivityCenter.shared.banner == nil, ActivityCenter.shared.peek == nil else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                    self.peekedGlance = item
                    self.peekAnchorX = anchorX
                }
            }
            if peekedGlance != nil { return work.perform() }
        } else {
            // A moment's grace, so crossing the gap to the next Glance doesn't flicker.
            work = DispatchWorkItem { [weak self] in self?.endGlancePeek() }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.45 : 0.12), execute: work)
    }

    func endGlancePeek() {
        peekWork?.cancel()
        guard peekedGlance != nil else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { peekedGlance = nil }
    }

    /// A peek shows only on the closed notch, and gives way to a Banner.
    var showsGlancePeek: Bool { peekedGlance != nil && !isOpen && ActivityCenter.shared.banner == nil && ActivityCenter.shared.reminder == nil }

    var collapsedSize: CGSize {
        var w = notchSize.width + 2 * sideWidth
        var h = notchSize.height
        // A Banner or a reminder tab hangs below; the Glances beside the notch stay as they are.
        let alerts = ActivityCenter.shared
        if alerts.banner != nil {
            w = max(w, ActivityCenter.bannerWidth(notchWidth: notchSize.width))
            h += ActivityCenter.bannerHeight
        } else if showsGlancePeek {
            w = max(w, ActivityCenter.bannerWidth(notchWidth: notchSize.width))
            h += GlancePeekCard.height
        } else if CaptionStrip.shared.showing {
            // Wide enough for a sentence to read at a glance.
            w = max(w, notchSize.width + 360)
            h += CaptionStrip.height
        } else if alerts.reminder != nil {
            w = max(w, notchSize.width + 60)
            h += ActivityCenter.reminderHeight
        }
        if showsStack {
            h += Self.stackHeight
            // Room to fan the files out on hover.
            if stackHovered { w = max(w, notchSize.width + 70) }
        }
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

    /// How the notch was last opened (or re-targeted by a shortcut while open).
    private(set) var openReason: OpenReason = .hover
    /// The pointer has been over the open panel since it opened. Moving the pointer towards a notch
    /// a shortcut opened mustn't close it; once it has been over the panel, leaving works as for a hover.
    var pointerVisited = false

    /// Whether the pointer leaving the panel should close it.
    var closesOnPointerExit: Bool { openReason == .hover || pointerVisited }

    func open(tab: NotchTab? = nil, takeKeyboard: Bool = true, reason: OpenReason = .click) {
        endGlancePeek()
        if takeKeyboard { wantsKeyboard = true }
        // A shortcut aimed at the open notch makes it stay put like a shortcut-opened one.
        if !isOpen || reason == .keyboard {
            openReason = reason
            pointerVisited = false
        }
        // The screen chosen in Settings (Search unless changed, or wherever it was left), unless
        // something was just dropped on the shelf: then it opens where those files are.
        let start = AppSettings.shared.openTo
        var target = tab ?? (start == "last" ? nil : NotchTab(rawValue: start).flatMap { tabs.contains($0) ? $0 : nil }
            ?? (tabs.contains(.ask) ? .ask : nil))
        if tab == nil, tabs.contains(.shelf), ShelfStore.shared.hasFreshDrop {
            target = .shelf
            UserDefaults.standard.set(ShelfPane.shelf.rawValue, forKey: "shelf.pane")
        }
        if isOpen {
            // Already open: slide over to a tab that was asked for (and stay put otherwise); a
            // shortcut also takes the keyboard, which a hover-opened notch may not have.
            if let tab, tabs.contains(tab) { select(tab) }
            if wantsKeyboard, reason == .keyboard { takeKeyFocus() }
            return
        }
        if let target, tabs.contains(target) { self.tab = target }
        // The app in front, read while the notch opens (a shortcut gives no hover head start).
        if self.tab == .ask { AppActions.shared.prepare() }
        // Opening covers the Banner; it's been seen.
        ActivityCenter.shared.dismissBanner()
        if overlay == nil, let prompt = NotchPresenter.shared.takePendingPrompt() { overlay = .prompt(prompt) }
        if reason == .hover { Haptics.align() }
        FrameProbe.mark("open")
        withAnimation(AppSettings.shared.openAnimation, completionCriteria: .logicallyComplete) {
            isOpen = true
        } completion: { [weak self] in
            guard let self, self.isOpen else { return }
            FrameProbe.mark("opened")
            self.isSettled = true
            self.prepareNeighbors()
            // The menus of the app in front, ready before anything is typed.
            if self.tab == .ask { MenuSearch.shared.prepare() }
        }
        // Take the keyboard as the open begins (before the content is built), so typing — or Esc on
        // a tab without a text field — works straight away; doing it after the animation re-rendered
        // the whole panel and dropped frames. (It has to follow `isOpen`: the window only takes the
        // keyboard while the notch is open.)
        if wantsKeyboard { takeKeyFocus() }
        FrameProbe.mark("keyed")
    }

    func close() {
        guard isOpen else { return }
        isSettled = false
        typeAhead = ""
        // A captured window is for questions asked now; the next open starts with plain search.
        AssistantStore.shared.clearContext()
        wantsKeyboard = false
        pager.builtCenter = nil
        pager.fromIndex = nil
        pager.reset(to: tabIndex)
        tabFlash = nil
        withAnimation(AppSettings.shared.closeAnimation) {
            isOpen = false
            isDragActive = false
            isEditing = false
            overlay = nil
            mirror = false
        }
    }

    /// Escape: steps back one level — a brief or the camera mirror first, then another tab back to
    /// search, then closes the notch. Text fields handle their own Escape (clear, stop editing) first.
    func backOut() {
        guard isOpen else { return }
        if overlay != nil || mirror {
            withAnimation(Motion.pane.animation) {
                overlay = nil
                mirror = false
            }
        } else if tabs.contains(.ask), tab != .ask {
            select(.ask)
        } else {
            close()
        }
    }

    /// The tab before (-1) or after (1), from the keyboard. At either end it stays put, as a swipe
    /// does. Returns whether the key was for this (the tabs are showing).
    func step(_ step: Int) -> Bool {
        guard isOpen, overlay == nil, !mirror, !isDragActive else { return false }
        let i = tabIndex + step
        guard tabs.indices.contains(i) else { return true }
        select(tabs[i])
        // Its name, briefly, where the battery is: the icons alone are small to go by.
        tabFlash = tabs[i]
        tabFlashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tabFlash = nil }
        tabFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
        return true
    }

    /// The tab just picked from the keyboard, named in the header for a moment.
    @Published var tabFlash: NotchTab?
    private var tabFlashWork: DispatchWorkItem?

    func select(_ tab: NotchTab) {
        wantsKeyboard = true
        guard tab != self.tab else { return }
        Haptics.tap()
        slide(to: tab, velocity: 0)
    }

    /// Moves to a tab. The tab changes at once, with the pages drawn where they were; the pager
    /// then springs them into place (`velocity` is the finger's, carried into the spring).
    func slide(to tab: NotchTab, velocity: CGFloat) {
        let new = tabs.firstIndex(of: tab) ?? tabIndex
        pager.slide(to: new, velocity: velocity, motion: .page, commit: {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { self.tab = tab }
        }, completion: { [weak self] in
            FrameProbe.mark("settled")
            self?.prepareNeighbors()
        })
    }

    /// Builds the pages either side of the current one once nothing is moving. The previous
    /// neighbours stay up until then: tearing them down as a slide settled and building the next
    /// ones as the following slide began were the two hitches in every swipe.
    private func prepareNeighbors() {
        // Late enough to stay clear of the first thing done after opening (typing, a click); a
        // swipe before then builds them at once (`ensureNeighbors`).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isOpen, !self.pager.isMoving else { return }
            guard self.pager.builtCenter != self.tabIndex || self.pager.fromIndex != nil else { return }
            FrameProbe.mark("neighbors")
            self.pager.builtCenter = self.tabIndex
            self.pager.fromIndex = nil
        }
    }

    /// A swipe needs the next page drawn. If the neighbours built are another page's (a swipe
    /// straight after arriving), build this one's now: otherwise the page coming in would be blank
    /// and pop in once it settled. The page left behind stays up (`fromIndex`) until then.
    func ensureNeighbors() {
        if pager.builtCenter != tabIndex { pager.builtCenter = tabIndex }
    }
}

