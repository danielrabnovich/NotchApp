import AppKit
import SwiftUI

/// A short-lived "live activity" that pops out of the collapsed notch.
enum SneakPeek: Equatable {
    case volume(level: Float, muted: Bool)
    case brightness(level: Float)
    case charging(level: Int)
    case meeting(title: String, minutes: Int, color: NSColor)
    case screenshot(count: Int)
    case timer(message: String)
    case download(name: String)
    case assistant(title: String, detail: String, isWeb: Bool)
    case taildrop(title: String, detail: String, received: Bool)
    /// A general confirmation: an icon, a title and a detail line.
    case notice(title: String, detail: String, icon: String)

    enum Kind: Equatable {
        case volume, brightness, charging, meeting, screenshot, timer, download, assistant, taildrop, notice

        func sideWidth(notchHeight h: CGFloat) -> CGFloat {
            switch self {
            case .volume, .brightness: 74
            case .charging: 78
            case .meeting, .screenshot, .timer, .download, .taildrop, .notice: h + 14
            case .assistant: 72
            }
        }

        var hasSubtitle: Bool { [.meeting, .screenshot, .timer, .download, .assistant, .taildrop, .notice].contains(self) }
    }

    var kind: Kind {
        switch self {
        case .volume: .volume
        case .brightness: .brightness
        case .charging: .charging
        case .meeting: .meeting
        case .screenshot: .screenshot
        case .timer: .timer
        case .download: .download
        case .assistant: .assistant
        case .taildrop: .taildrop
        case .notice: .notice
        }
    }
}

@MainActor
final class ActivityCenter: ObservableObject {
    static let shared = ActivityCenter()

    @Published private(set) var peek: SneakPeek?
    private var hideWork: DispatchWorkItem?

    func show(_ peek: SneakPeek, for duration: TimeInterval) {
        hideWork?.cancel()
        if self.peek?.kind == peek.kind {
            self.peek = peek // same layout: update in place without re-animating size
        } else {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { self.peek = peek }
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { self?.peek = nil }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
