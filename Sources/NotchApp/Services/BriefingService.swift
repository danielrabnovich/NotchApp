import AppKit
import EventKit
import SwiftUI

/// Content the notch can drop down with on its own (not from a hover).
enum NotchOverlay: Equatable {
    case brief(Brief)
    case nudge(Nudge)
    case prompt(Prompt)
}

/// A heads-up with buttons ("localhost:5173 is up · Open", "Design review in 3 min · Join"). It's
/// shown as a quick peek first; opening the notch while it's fresh shows it with its actions.
struct Prompt: Equatable, Identifiable {
    struct Action {
        let title: String
        var primary = false
        let run: @MainActor () -> Void
    }

    let id = UUID()
    let icon: String
    var tint: NSColor = .white
    let title: String
    let detail: String
    let actions: [Action]
    var created = Date()

    static func == (a: Prompt, b: Prompt) -> Bool { a.id == b.id }
}

struct Brief: Equatable {
    struct Item: Equatable, Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
        let color: NSColor
    }
    var greeting: String
    var summary: String
    var aiWritten = false
    var items: [Item]
    var focusTaskID: UUID?
}

struct Nudge: Equatable {
    let taskID: UUID
    let title: String
    let dueText: String
    let overdue: Bool
    var message: String
    let hasLink: Bool
}

/// Routes app-initiated presentations to the main notch.
@MainActor
final class NotchPresenter {
    static let shared = NotchPresenter()
    weak var primary: NotchViewModel?

    func open(tab: NotchTab) {
        primary?.overlay = nil
        primary?.open(tab: tab, reason: .system)
    }

    func present(_ overlay: NotchOverlay) {
        guard let vm = primary else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { vm.overlay = overlay }
        vm.open(reason: .system)
    }

    func dismissOverlay(close: Bool) {
        guard let vm = primary else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { vm.overlay = nil }
        if close { vm.close() }
    }

    var isBusy: Bool { primary?.isOpen == true || primary?.overlay != nil }

    /// The latest prompt, offered when the notch next opens (for half a minute).
    private(set) var pendingPrompt: Prompt?

    /// Peeks the prompt beside the notch now; its buttons show if the notch is opened soon after.
    func offer(_ prompt: Prompt, peek: Bool = true, peekFor seconds: TimeInterval = 6) {
        pendingPrompt = prompt
        if peek { ActivityCenter.shared.show(.notice(title: prompt.title, detail: prompt.detail, icon: prompt.icon, tone: .action), for: seconds) }
        if let vm = primary, vm.isOpen, vm.overlay == nil {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { vm.overlay = .prompt(prompt) }
        }
    }

    /// How long an unanswered prompt stays on offer from the tab under the notch.
    static let reminderLifetime: TimeInterval = 300

    /// A prompt is still on offer (for the tab under the notch).
    var hasRecentPrompt: Bool {
        guard let p = pendingPrompt else { return false }
        return Date().timeIntervalSince(p.created) < Self.reminderLifetime
    }

    /// The tab under the notch was clicked: show the prompt it stands for, with its buttons.
    func reopenPending() {
        ActivityCenter.shared.clearReminder()
        guard let p = pendingPrompt, Date().timeIntervalSince(p.created) < Self.reminderLifetime else { return }
        pendingPrompt = nil
        present(.prompt(p))
    }

    func hasPendingPrompt(titled title: String) -> Bool {
        guard let p = pendingPrompt else { return false }
        return p.title == title && Date().timeIntervalSince(p.created) < 30
    }

    /// Called as the notch opens: hands over a fresh prompt.
    func takePendingPrompt() -> Prompt? {
        defer { pendingPrompt = nil }
        ActivityCenter.shared.clearReminder()
        guard let p = pendingPrompt, Date().timeIntervalSince(p.created) < 30 else { return nil }
        return p
    }
}

/// Morning brief on the first unlock of the day, and "due soon" nudges for tasks.
@MainActor
final class BriefingService {
    static let shared = BriefingService()

    private var timer: Timer?
    private var snoozedUntil: [UUID: Date] = [:]
    private var nudgeDismissWork: DispatchWorkItem?
    private let settings = AppSettings.shared
    private let lastBriefKey = "lastBriefDay"

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { BriefingService.shared.maybeShowBrief() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { BriefingService.shared.maybeShowBrief() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { BriefingService.shared.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.tick() }
    }

    private func tick() {
        maybeShowBrief()
        checkNudges()
    }

    private var screenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    // MARK: - Morning brief

    func maybeShowBrief(force: Bool = false) {
        Birthdays.shared.refreshIfStale()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        if !force {
            guard settings.morningBrief, !screenLocked, !NotchPresenter.shared.isBusy,
                  cal.component(.hour, from: Date()) >= settings.briefHour else { return }
            if let last = UserDefaults.standard.object(forKey: lastBriefKey) as? Date, last >= today { return }
        }
        UserDefaults.standard.set(Date(), forKey: lastBriefKey)

        var brief = makeBrief()
        NotchPresenter.shared.present(.brief(brief))

        guard AssistantStore.shared.status == .ready || AssistantStore.shared.status == .unknown else { return }
        let facts = brief.items.map { "- \($0.title) (\($0.detail))" }.joined(separator: "\n")
        Task {
            let system = """
            Write the user's daily brief: 1–2 short sentences, max 40 words, warm and direct, second person. \
            Point out the most urgent item and suggest where to start. No greeting, no emojis, no lists. \
            If there's nothing scheduled, encourage them briefly.
            """
            guard let text = try? await OllamaClient.chat(system: system, user: "Today:\n\(facts.isEmpty ? "Nothing scheduled." : facts)", temperature: 0.6),
                  !text.isEmpty,
                  case .brief(let current)? = NotchPresenter.shared.primary?.overlay,
                  current.greeting == brief.greeting else { return }
            brief.summary = text
            brief.aiWritten = true
            withAnimation(.easeInOut(duration: 0.35)) { NotchPresenter.shared.primary?.overlay = .brief(brief) }
        }
    }

    private func makeBrief() -> Brief {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let greeting = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        let endOfToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let time = Date.FormatStyle(date: .omitted, time: .shortened)

        let open = TaskStore.shared.open
        let overdue = open.filter(\.isOverdue)
        let dueToday = open.filter { !$0.isOverdue && ($0.due.map { $0 < endOfToday } ?? false) }
        let meetings = CalendarManager.shared.events.filter { !$0.isAllDay && $0.endDate > now }

        var items: [Brief.Item] = []
        for p in Birthdays.shared.today {
            items.append(.init(icon: "birthday.cake.fill", title: "\(p.name)'s birthday",
                               detail: p.turning.map { "Turning \($0)" } ?? "Today", color: .systemPink))
        }
        for t in overdue { items.append(.init(icon: "exclamationmark.circle.fill", title: t.title, detail: "Overdue", color: .systemRed)) }
        for t in dueToday { items.append(.init(icon: "clock.fill", title: t.title, detail: "Due \(t.due!.formatted(time))", color: .systemOrange)) }
        for e in meetings.prefix(4) {
            items.append(.init(icon: "calendar", title: e.title ?? "Event", detail: e.startDate.formatted(time),
                               color: e.calendar?.color ?? .systemBlue))
        }
        let others = open.count - overdue.count - dueToday.count
        if others > 0 {
            items.append(.init(icon: "checklist", title: "\(others) other open task\(others == 1 ? "" : "s")", detail: "No rush", color: .systemGray))
        }

        var parts: [String] = []
        if !overdue.isEmpty { parts.append("\(overdue.count) overdue") }
        if !dueToday.isEmpty { parts.append("\(dueToday.count) due today") }
        if !meetings.isEmpty { parts.append("\(meetings.count) meeting\(meetings.count == 1 ? "" : "s")") }
        let summary = parts.isEmpty ? "Nothing urgent today. A good day to get ahead." : "You have " + parts.joined(separator: ", ") + "."

        return Brief(greeting: greeting, summary: summary, items: items,
                     focusTaskID: (overdue.first ?? dueToday.first ?? open.first)?.id)
    }

    // MARK: - Due-soon nudges

    private func checkNudges() {
        guard settings.dueNudges, settings.tasksEnabled, !screenLocked, !NotchPresenter.shared.isBusy else { return }
        let now = Date()
        let lead = TimeInterval(settings.nudgeLeadMinutes * 60)

        for task in TaskStore.shared.open {
            guard let due = task.due else { continue }
            if let until = snoozedUntil[task.id] {
                if now < until { continue }
                snoozedUntil[task.id] = nil
                nudge(task, due: due)
                return
            }
            let remaining = due.timeIntervalSince(now)
            let nudged = task.nudgedAt ?? .distantPast
            if remaining > 0, remaining <= lead, nudged < due.addingTimeInterval(-lead) {
                nudge(task, due: due); return
            }
            if remaining <= 0, remaining > -6 * 3600, nudged < due {
                nudge(task, due: due); return
            }
        }
    }

    private func nudge(_ task: TaskItem, due: Date) {
        TaskStore.shared.markNudged(task.id)
        let remaining = due.timeIntervalSinceNow
        let overdue = remaining <= 0
        let span = Self.duration(abs(remaining))
        let dueText = overdue ? "Overdue by \(span)" : "Due in \(span)"
        var nudge = Nudge(taskID: task.id, title: task.title, dueText: dueText, overdue: overdue,
                          message: overdue ? "Want to wrap it up now?" : "Start now and future you will thank you.",
                          hasLink: task.link != nil)
        NotchPresenter.shared.present(.nudge(nudge))
        Haptics.level()
        scheduleNudgeDismiss()

        Task {
            let system = """
            Nudge the user to start a task. One sentence, max 22 words, friendly and concrete: \
            suggest a tiny first step they can do in 5 minutes. No emojis, no quotes.
            """
            let user = "Task: \(task.title)\(task.note.map { "\nNotes: \($0.prefix(400))" } ?? "")\nStatus: \(dueText)"
            guard let text = try? await OllamaClient.chat(system: system, user: user, temperature: 0.7), !text.isEmpty,
                  case .nudge(let current)? = NotchPresenter.shared.primary?.overlay, current.taskID == task.id else { return }
            nudge.message = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            withAnimation(.easeInOut(duration: 0.3)) { NotchPresenter.shared.primary?.overlay = .nudge(nudge) }
        }
    }

    /// Nudges tuck themselves away if ignored; the task stays in the list.
    private func scheduleNudgeDismiss() {
        nudgeDismissWork?.cancel()
        let work = DispatchWorkItem {
            guard case .nudge? = NotchPresenter.shared.primary?.overlay,
                  NotchPresenter.shared.primary?.isHovering == false else { return }
            NotchPresenter.shared.dismissOverlay(close: true)
        }
        nudgeDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    // MARK: - Nudge actions

    func start(_ nudge: Nudge) {
        nudgeDismissWork?.cancel()
        if let task = TaskStore.shared.tasks.first(where: { $0.id == nudge.taskID }) {
            TaskStore.shared.openLink(of: task)
        }
        NotchPresenter.shared.open(tab: .tasks)
    }

    func snooze(_ nudge: Nudge, minutes: Int = 30) {
        nudgeDismissWork?.cancel()
        snoozedUntil[nudge.taskID] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        NotchPresenter.shared.dismissOverlay(close: true)
    }

    func complete(_ nudge: Nudge) {
        nudgeDismissWork?.cancel()
        TaskStore.shared.setDone(nudge.taskID, true)
        NotchPresenter.shared.dismissOverlay(close: true)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes))m" }
        let h = minutes / 60, m = minutes % 60
        if h < 24 { return m == 0 ? "\(h)h" : "\(h)h \(m)m" }
        return "\(h / 24)d"
    }
}
