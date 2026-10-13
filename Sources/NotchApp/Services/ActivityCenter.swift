import AppKit
import SwiftUI

/// How a heads-up reads: done (a green check), for information (a dot), something wrong (orange),
/// or waiting in the open notch with buttons (a chevron).
enum NoticeTone: Equatable {
    case success, info, warning, action
}

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
    /// A general heads-up: an icon, a title and a detail line. The tone picks the mark on the right.
    case notice(title: String, detail: String, icon: String, tone: NoticeTone = .success)
    /// Another app's notification (a message), shown in place of the system's banner.
    case message(id: String, app: String, bundleID: String?, sender: String, text: String, replyable: Bool)

    enum Kind: Equatable {
        case volume, brightness, charging, meeting, screenshot, timer, download, assistant, taildrop, notice, message

        func sideWidth(notchHeight h: CGFloat) -> CGFloat {
            switch self {
            case .volume, .brightness: 92
            case .charging: 78
            case .meeting, .screenshot, .timer, .download, .taildrop, .notice, .message: h + 14
            case .assistant: 72
            }
        }

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
        case .message: .message
        }
    }
}

extension SneakPeek {
    /// How it's shown. A Flash takes over a wing for a moment (volume, brightness, charging); a
    /// Banner drops down under the notch and leaves the Glances alone; a Prompt is a Banner that
    /// wants an answer, and folds into a tab under the notch if it isn't given one.
    enum Tier { case flash, banner, prompt }

    var tier: Tier {
        switch self {
        case .volume, .brightness, .charging: .flash
        case .meeting: .prompt
        case let .notice(_, _, _, tone): tone == .action ? .prompt : .banner
        default: .banner
        }
    }

    /// The Banner's two lines.
    @MainActor var bannerText: (title: String, detail: String) {
        switch self {
        case let .meeting(title, minutes, _): (title, "In \(minutes) min")
        case let .screenshot(count):
            (count == 1 ? "Screenshot on Shelf" : "\(count) screenshots on Shelf", AppSettings.shared.copyShelfAdds ? "Copied too" : "Drag it anywhere")
        case let .timer(message): (message, "Timer")
        case let .download(name): ("Downloaded", name)
        case let .assistant(title, detail, _), let .taildrop(title, detail, _), let .notice(title, detail, _, _): (title, detail)
        case let .message(_, _, _, sender, text, _): (sender, text)
        case .volume, .brightness, .charging: ("", "")
        }
    }
}

@MainActor
final class ActivityCenter: ObservableObject {
    static let shared = ActivityCenter()

    /// The Flash in the wings right now.
    @Published private(set) var peek: SneakPeek?
    /// The Banner (or Prompt) hanging under the notch right now.
    @Published private(set) var banner: SneakPeek?
    /// A Prompt that went unanswered: a slim tab under the notch until it's opened or goes stale.
    @Published private(set) var reminder: String?

    private var hideWork: DispatchWorkItem?
    private var bannerWork: DispatchWorkItem?
    private var reminderWork: DispatchWorkItem?
    private var bannerDuration: TimeInterval = 4
    private var queue: [(peek: SneakPeek, duration: TimeInterval, added: Date)] = []
    /// The pointer is on the Banner: it stays until the pointer leaves.
    private var holding = false

    func show(_ peek: SneakPeek, for duration: TimeInterval) {
        if peek.tier == .flash { return flash(peek, for: duration) }
        let level = AppSettings.shared.alertLevel
        if level == .none || (level == .important && peek.tier != .prompt) { return }
        // The same Banner again (a second screenshot, a progress update): change it in place.
        if let current = banner, current.kind == peek.kind, current.bannerText.title == peek.bannerText.title || peek.kind == .screenshot {
            banner = peek
            schedule(for: max(duration, bannerDuration))
            return
        }
        queue.removeAll { $0.peek == peek }
        queue.append((peek, duration, Date()))
        // Only the latest few are worth catching up on.
        if queue.count > 3 { queue.removeFirst(queue.count - 3) }
        if banner == nil { next() }
    }

    private func flash(_ peek: SneakPeek, for duration: TimeInterval) {
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

    /// Shows the next queued Banner. While a full-screen app is in front they wait (a minute at
    /// most) rather than dropping over a film or a presentation.
    private func next() {
        queue.removeAll { Date().timeIntervalSince($0.added) > 60 }
        guard banner == nil, !queue.isEmpty else { return }
        if FullScreen.isFrontmost() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.next() }
            return
        }
        let item = queue.removeFirst()
        if item.peek.tier == .prompt { clearReminder() }
        Haptics.level()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { banner = item.peek }
        // Long enough to read; a Prompt longer, since it's asking something.
        let minimum: TimeInterval = item.peek.tier == .prompt ? 8 : 3.5
        schedule(for: max(item.duration, minimum))
    }

    private func schedule(for duration: TimeInterval) {
        bannerDuration = duration
        bannerWork?.cancel()
        guard !holding else { return }
        let work = DispatchWorkItem { [weak self] in self?.endBanner() }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// The pointer moved onto or off the Banner.
    func hold(_ on: Bool) {
        guard on != holding, banner != nil else { return }
        holding = on
        if on { bannerWork?.cancel() } else { schedule(for: 1.5) }
    }

    /// Takes the Banner down now (it was clicked, or the notch opened over it).
    func dismissBanner() {
        bannerWork?.cancel()
        holding = false
        guard banner != nil else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { banner = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.next() }
    }

    private func endBanner() {
        let ended = banner
        dismissBanner()
        // An unanswered Prompt folds into a tab under the notch while its buttons are still on offer.
        if let ended, ended.tier == .prompt, NotchPresenter.shared.hasRecentPrompt {
            let title = ended.bannerText.title
            withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { reminder = title }
            reminderWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.clearReminder() }
            reminderWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchPresenter.reminderLifetime, execute: work)
        }
    }

    func clearReminder() {
        reminderWork?.cancel()
        guard reminder != nil else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { reminder = nil }
    }

    /// Height the Banner or reminder tab adds under the collapsed notch.
    var extraHeight: CGFloat { banner != nil ? Self.bannerHeight : reminder != nil ? Self.reminderHeight : 0 }
    /// Width the Banner needs (the notch widens to at least this).
    static func bannerWidth(notchWidth: CGFloat) -> CGFloat { notchWidth + 180 }
    static let bannerHeight: CGFloat = 54
    static let reminderHeight: CGFloat = 24
}

/// Whether the frontmost app fills its screen (a full-screen window, a video, a presentation).
@MainActor
enum FullScreen {
    static func isFrontmost() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let sizes = NSScreen.screens.map(\.frame.size)
        return windows.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return sizes.contains { abs($0.width - (b["Width"] ?? 0)) < 1 && abs($0.height - (b["Height"] ?? 0)) < 1 }
        }
    }
}
