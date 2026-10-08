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
    @Published var isHovering = false
    @Published var tab: NotchTab = AppSettings.shared.assistantEnabled ? .ask : .home

    /// Something is being dragged over the notch from another app; show the drop bins.
    @Published var isDragActive = false
    @Published var dragPreview: DragPreview?

    /// Live horizontal offset while two-finger swiping between tabs.
    @Published var pageOffset: CGFloat = 0
    @Published var isSwiping = false
    var pageWidth: CGFloat = 600

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
        t.append(.home)
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

    func open(tab: NotchTab? = nil) {
        // Search is the default view each time the notch opens.
        let target = tab ?? (tabs.contains(.ask) ? .ask : nil)
        if let target, tabs.contains(target) { self.tab = target }
        guard !isOpen else { return }
        withAnimation(AppSettings.shared.openAnimation) { isOpen = true }
    }

    func close() {
        guard isOpen else { return }
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
        guard tab != self.tab else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
            self.tab = tab
            pageOffset = 0
        }
    }
}
