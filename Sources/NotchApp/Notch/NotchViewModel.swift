import AppKit
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case home, shelf, tasks
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house.fill"
        case .shelf: "tray.full.fill"
        case .tasks: "checklist"
        }
    }
}

/// What the collapsed notch is currently showing beside the hardware notch.
enum CollapsedActivity: Equatable {
    case none
    case music
    case tasks
    case peek(SneakPeek.Kind)
}

/// Per-screen notch state.
@MainActor
final class NotchViewModel: ObservableObject {
    let notchSize: CGSize
    let hasPhysicalNotch: Bool

    @Published var isOpen = false
    @Published var isHovering = false
    @Published var tab: NotchTab = .home

    /// Something is being dragged over the notch from another app; show the drop bins.
    @Published var isDragActive = false
    @Published var dragPreview: DragPreview?

    /// Live horizontal offset while two-finger swiping between tabs.
    @Published var pageOffset: CGFloat = 0
    @Published var isSwiping = false
    var pageWidth: CGFloat = 600

    /// A text field inside the notch has keyboard focus – don't auto-close.
    @Published var isEditing = false

    /// Area (in hosting-view coordinates, top-left origin) that scrolls horizontally on its own.
    var horizontalScrollRegion: CGRect?

    /// Corner radii for the black shape (top flare / bottom rounding).
    var topRadius: CGFloat { isOpen ? 14 : 6 }
    var bottomRadius: CGFloat { isOpen ? 26 : (hasPhysicalNotch ? 10 : 12) }

    init(notchSize: CGSize, hasPhysicalNotch: Bool) {
        self.notchSize = notchSize
        self.hasPhysicalNotch = hasPhysicalNotch
    }

    var openSize: CGSize { CGSize(width: max(640, notchSize.width + 420), height: notchSize.height + 168) }

    var tabs: [NotchTab] {
        let s = AppSettings.shared
        var t: [NotchTab] = [.home]
        if s.shelfEnabled { t.append(.shelf) }
        if s.tasksEnabled { t.append(.tasks) }
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
        if let tab, tabs.contains(tab) { self.tab = tab }
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
