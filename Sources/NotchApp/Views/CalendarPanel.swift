import EventKit
import SwiftUI

/// Home's day at a glance: the date and the weather, what's up next (with a countdown, or Join
/// when the call is about to start), the rest of today's events, and the tasks due today.
/// `wide` when it has Home to itself (nothing playing): events and tasks side by side.
struct TodayPanel: View {
    var wide = false
    @EnvironmentObject private var calendar: CalendarManager
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var weather = TodayWeather.shared
    @ObservedObject private var birthdays = Birthdays.shared

    var body: some View {
        // A minute is fine enough for "in 25 min" and for when the next event moves up.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 8) {
                header
                // Someone's birthday: a line of its own, first thing.
                if !birthdays.today.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "birthday.cake.fill").foregroundStyle(.pink)
                        Text(birthdays.today.map { p in p.turning.map { "\(p.name) turns \($0)" } ?? "\(p.name)'s birthday" }.joined(separator: " · "))
                            .lineLimit(1)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                }
                if settings.calendarEnabled, !calendar.hasAccess {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("See today's events here.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                        Button("Allow Calendar Access") { calendar.requestAccess() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                } else {
                    content(now: now)
                }
            }
        }
        .onAppear {
            weather.refreshIfStale()
            birthdays.refreshIfStale()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Date.now, format: .dateTime.weekday(.wide))
                .font(.system(size: 13, weight: .semibold))
            Text(Date.now, format: .dateTime.month(.abbreviated).day())
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 4)
            if let report = weather.report {
                HStack(spacing: 4) {
                    Image(systemName: WeatherReport.symbol(report.currentCode))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 11))
                    Text("\(Int(report.currentTemp.rounded()))°")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
                .help(report.summary)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { calendar.openCalendar() }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let events = settings.calendarEnabled ? calendar.events.filter { $0.isAllDay || $0.endDate > now } : []
        // The next timed event: on now, or still to come today; else the first one in the coming week.
        let today = events.first { !$0.isAllDay }
        let next = today ?? (settings.calendarEnabled ? calendar.later : nil)
        let rest = events.filter { $0 !== today }
        let due = settings.tasksEnabled ? dueToday(now) : []
        // With room to spare and nothing due, the top of the list instead.
        let shownTasks = due.isEmpty && wide && settings.tasksEnabled ? Array(tasks.open.prefix(4)) : due

        if next == nil, rest.isEmpty, shownTasks.isEmpty {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                Text(settings.calendarEnabled ? "Nothing else today" : "Nothing due today")
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        } else if wide {
            HStack(alignment: .top, spacing: 14) {
                if next != nil || !rest.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if let next { UpNextCard(event: next, now: now) }
                        eventList(rest)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !shownTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle(text: due.isEmpty ? "Tasks" : "Due today")
                        taskList(shownTasks, now: now)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        } else {
            if let next { UpNextCard(event: next, now: now) }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    taskList(due, now: now)
                    eventList(rest)
                }
            }
        }
    }

    private func eventList(_ events: [EKEvent]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(events, id: \.calendarItemIdentifier) { EventRow(event: $0) }
            }
        }
    }

    @ViewBuilder private func taskList(_ due: [TaskItem], now: Date) -> some View {
        if !due.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(due.prefix(wide ? 4 : 3)) { TodayTaskRow(task: $0, now: now) }
            }
        }
    }

    /// Open tasks due by the end of today, overdue ones included, soonest first.
    private func dueToday(_ now: Date) -> [TaskItem] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        return tasks.open.filter { ($0.due ?? .distantFuture) < end }
    }
}

/// The next event, larger: when it starts (or that it's on now), and Join once it's close.
private struct UpNextCard: View {
    let event: EKEvent
    let now: Date

    var body: some View {
        let color = Color(nsColor: event.calendar?.color ?? .systemBlue)
        let link = MeetingLinks.find(in: event)
        let soon = event.startDate.timeIntervalSince(now) < 15 * 60
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(when)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(soon ? color : .white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if soon, let link {
                Button("Join") { MeetingLinks.join(link) }
                    .buttonStyle(NotchPillButtonStyle(primary: true, height: 22))
                    .help("Join on \(link.service)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.14)))
    }

    /// "in 25 min · 3:00 PM", "Now · until 3:30 PM", "at 5:00 PM", "Tomorrow · 9:00 AM".
    private var when: String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if !cal.isDate(event.startDate, inSameDayAs: now) {
            let day = cal.isDateInTomorrow(event.startDate) ? "Tomorrow" : event.startDate.formatted(.dateTime.weekday(.wide))
            return "\(day) · \(event.startDate.formatted(time))"
        }
        if event.startDate <= now { return "Now · until \(event.endDate.formatted(time))" }
        let minutes = Int((event.startDate.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min · \(event.startDate.formatted(time))" }
        if minutes < 180 { return "in \(minutes / 60)h \(minutes % 60)m · \(event.startDate.formatted(time))" }
        return "at \(event.startDate.formatted(time))"
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.35))
    }
}

/// A task due today: tick it off right here.
private struct TodayTaskRow: View {
    let task: TaskItem
    let now: Date
    @EnvironmentObject private var tasks: TaskStore

    var body: some View {
        HStack(spacing: 7) {
            Button {
                withAnimation(Motion.small.animation) { tasks.setDone(task.id, true) }
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Mark as done")
            Text(task.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let due = task.due {
                Text(due < now ? "Overdue" : due.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(due < now ? Color.orange.opacity(0.85) : .white.opacity(0.45))
            }
        }
        .frame(height: 22)
    }
}

/// Today's weather for Home's header, fetched at most every half hour (and never if it fails: no
/// error to show, the header just goes without).
@MainActor
final class TodayWeather: ObservableObject {
    static let shared = TodayWeather()
    @Published private(set) var report: WeatherReport?
    private var fetchedAt = Date.distantPast

    func refreshIfStale() {
        guard Date().timeIntervalSince(fetchedAt) > 30 * 60 else { return }
        fetchedAt = Date()
        Task {
            guard let report = try? await WeatherService.report(location: nil, dayOffset: 0) else {
                fetchedAt = Date().addingTimeInterval(-25 * 60) // try again in five minutes
                return
            }
            withAnimation(.easeOut(duration: 0.2)) { self.report = report }
        }
    }
}

private struct EventRow: View {
    let event: EKEvent

    var body: some View {
        let now = Date()
        let ongoing = !event.isAllDay && event.startDate <= now && event.endDate > now
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: event.calendar?.color ?? .systemBlue))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(timeText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
            // A Join button from 15 minutes before until the call ends.
            if !event.isAllDay, event.endDate > now, event.startDate.timeIntervalSince(now) < 15 * 60,
               let link = MeetingLinks.find(in: event) {
                Button("Join") { MeetingLinks.join(link) }
                    .buttonStyle(NotchPillButtonStyle(primary: true, height: 20))
                    .help("Join on \(link.service)")
            } else if ongoing {
                Text("Now")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: event.calendar?.color ?? .systemBlue).opacity(0.35)))
            }
        }
        .frame(height: 30)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(event.startDate.formatted(f)) – \(event.endDate.formatted(f))"
    }
}
