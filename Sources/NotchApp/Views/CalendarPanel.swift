import EventKit
import SwiftUI

/// Home's day at a glance: the month and this week (tap a day to see its events), today's events
/// (with a countdown, or Join when the call is about to start), and the tasks due today. Beside a
/// playing song it takes half of Home (`half`); beside the small music card, a few more tasks
/// (`full`), with tasks in a column of their own when music isn't on Home (`roomy`).
struct TodayPanel: View {
    enum Layout { case half, full, roomy }
    /// The month and week strip's line, which the weather beside it lines up with.
    static let headerHeight: CGFloat = 45
    var layout: Layout = .half
    private var wide: Bool { layout != .half }
    @EnvironmentObject private var calendar: CalendarManager
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var weather = TodayWeather.shared
    @ObservedObject private var birthdays = Birthdays.shared
    /// A day tapped in the week strip; nil is today.
    @State private var picked: Date?

    var body: some View {
        // A minute is fine enough for "in 25 min" and for when the next event moves up.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 10) {
                header(now: now)
                if settings.calendarEnabled, !calendar.hasAccess {
                    VStack(alignment: .leading, spacing: 8) {
                        birthdayLine
                        Text("See today's events here.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                        Button("Allow Calendar Access") { calendar.requestAccess() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if let picked, !Calendar.current.isDate(picked, inSameDayAs: now) {
                            dayList(picked, now: now)
                        } else {
                            birthdayLine
                            content(now: now)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .onDisappear { picked = nil }
        .onAppear {
            weather.refreshIfStale()
            birthdays.refreshIfStale()
        }
    }

    /// Someone's birthday: the first line of today's column, never a row across the whole panel (that
    /// pushed the forecast below it out of the notch).
    @ViewBuilder private var birthdayLine: some View {
        if !birthdays.today.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "birthday.cake.fill").foregroundStyle(.pink)
                Text(birthdays.today.map { p in p.turning.map { "\(p.name) turns \($0)" } ?? "\(p.name)'s birthday" }.joined(separator: " · "))
                    .lineLimit(1)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(picked ?? now, format: .dateTime.month(.abbreviated))
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
                .onTapGesture { calendar.openCalendar() }
                .help("Open Calendar")
            WeekStrip(now: now, events: settings.calendarEnabled ? calendar.week : [], pitch: 30,
                      picked: settings.calendarEnabled ? $picked : .constant(nil))
            Spacer(minLength: 0)
        }
    }

    /// A day other than today, picked in the week strip: all of its events.
    @ViewBuilder private func dayList(_ day: Date, now: Date) -> some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let events = calendar.week.filter { $0.startDate < end && $0.endDate > start }
        if events.isEmpty {
            Spacer(minLength: 0)
            Text("Nothing on \(day.formatted(.dateTime.weekday(.wide)))")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        } else {
            eventList(events, now: now)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let events = settings.calendarEnabled ? calendar.events.filter { $0.isAllDay || $0.endDate > now } : []
        // The next timed event: on now, or still to come today; else the first one in the coming week.
        let today = events.first { !$0.isAllDay }
        let next = today ?? (settings.calendarEnabled ? calendar.later : nil)
        // Nothing timed left today: the next event in the coming week goes at the end, with its day.
        let shown = today == nil ? events + (next.map { [$0] } ?? []) : events
        let due = settings.tasksEnabled ? dueToday(now) : []
        // With room to spare and nothing due, the top of the list instead.
        let shownTasks = due.isEmpty && wide && settings.tasksEnabled ? Array(tasks.open.prefix(4)) : due

        if shown.isEmpty, shownTasks.isEmpty {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                Text(settings.calendarEnabled ? "Nothing else today" : "Nothing due today")
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        } else if layout == .roomy {
            HStack(alignment: .top, spacing: 14) {
                if !shown.isEmpty {
                    eventList(shown, now: now)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !shownTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle(text: due.isEmpty ? "Tasks" : "Due today")
                        ScrollView(.vertical, showsIndicators: false) { taskList(shownTasks, now: now) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    taskList(shownTasks, now: now)
                    rows(shown, now: now)
                }
            }
        }
    }

    private func eventList(_ events: [EKEvent], now: Date) -> some View {
        ScrollView(.vertical, showsIndicators: false) { rows(events, now: now) }
    }

    private func rows(_ events: [EKEvent], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(events, id: \.calendarItemIdentifier) { EventRow(event: $0, now: now) }
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

/// Home's weather card: the weather now, on the line of Today's header beside it, and the next few
/// days under it.
struct HomeWeatherCard: View {
    let report: WeatherReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WeatherNow(report: report)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: TodayPanel.headerHeight)
            if report.days.count > 1 {
                Forecast(report: report)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The weather now: its symbol, the temperature, and today's range.
private struct WeatherNow: View {
    let report: WeatherReport

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: WeatherReport.symbol(report.currentCode))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Int(report.currentTemp.rounded()))°")
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                if let today = report.days.first {
                    Text("H \(Int(today.high.rounded()))°  L \(Int(today.low.rounded()))°")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .help(report.summary)
    }
}

/// The weather beyond the header: what it's like out, then the next few days.
private struct Forecast: View {
    let report: WeatherReport

    var body: some View {
        // As many days as fit under the header (a call bar above Home takes some of the height).
        ViewThatFits(in: .vertical) {
            column(days: 3)
            column(days: 2)
            column(days: 1)
            column(days: 0)
        }
    }

    private func column(days: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(WeatherReport.describe(report.currentCode))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.bottom, 2)
            ForEach(report.days.dropFirst().prefix(days)) { day in
                HStack(spacing: 6) {
                    Text(day.date, format: .dateTime.weekday(.abbreviated))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 30, alignment: .leading)
                    Image(systemName: WeatherReport.symbol(day.code))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 11))
                        .frame(width: 18)
                    Spacer(minLength: 0)
                    Text("\(Int(day.high.rounded()))°")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    Text("\(Int(day.low.rounded()))°")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 26, alignment: .trailing)
                }
                .help(WeatherReport.describe(day.code) + (day.rainChance > 0 ? ", \(day.rainChance)% chance of rain" : ""))
            }
        }
    }

    /// "Feels 55° · Rain 40%", the rain only once it's likely enough to matter.
    private var detail: String {
        var parts = ["Feels \(Int(report.feelsLike.rounded()))°"]
        if let today = report.days.first, today.rainChance >= 20 { parts.append("Rain \(today.rainChance)%") }
        else { parts.append("\(report.humidity)% humid") }
        return parts.joined(separator: " · ")
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

    /// Debug (`homeshot`): shows this instead, until the next fetch.
    func preview(_ report: WeatherReport?) { self.report = report }

    func refreshIfStale(force: Bool = false) {
        guard force || Date().timeIntervalSince(fetchedAt) > 30 * 60 else { return }
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

/// An event: its title and where it is, and on the right when it starts (in its calendar's color
/// once it's close or on now), or Join for a call about to start.
private struct EventRow: View {
    let event: EKEvent
    let now: Date

    var body: some View {
        let color = Color(nsColor: event.calendar?.color ?? .systemBlue)
        let link = !event.isAllDay && event.endDate > now && event.startDate.timeIntervalSince(now) < 15 * 60
            ? MeetingLinks.find(in: event) : nil
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            // A Join button from 15 minutes before until the call ends.
            if let link {
                Button("Join") { MeetingLinks.join(link) }
                    .buttonStyle(NotchPillButtonStyle(primary: true, height: 20))
                    .help("Join on \(link.service)")
            } else {
                let (text, soon) = when
                Text(text)
                    .font(.system(size: 11.5, weight: soon ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(soon ? color : .white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(height: 30)
    }

    /// Where it is (the first line of the address), else its times.
    private var detail: String? {
        if let place = event.location?.split(whereSeparator: \.isNewline).first, !place.isEmpty { return String(place) }
        if event.isAllDay { return nil }
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(event.startDate.formatted(f)) – \(event.endDate.formatted(f))"
    }

    /// "Now", "in 25 min" (both in its color), "13:30", "Tomorrow 9:00", "All day".
    private var when: (String, Bool) {
        if event.isAllDay { return ("All day", false) }
        let time = event.startDate.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if event.startDate <= now, event.endDate > now { return ("Now", true) }
        if event.startDate > now, !cal.isDate(event.startDate, inSameDayAs: now) {
            let day = cal.isDateInTomorrow(event.startDate) ? "Tomorrow" : event.startDate.formatted(.dateTime.weekday(.abbreviated))
            return ("\(day) \(time)", false)
        }
        let minutes = Int((event.startDate.timeIntervalSince(now) / 60).rounded(.up))
        if minutes > 0, minutes < 60 { return ("in \(minutes) min", true) }
        return (time, false)
    }
}

/// This calendar week, a day to a column: today in red, the weekend brighter, dots in the colors
/// of each day's calendars. Tapping a day picks it; tapping today goes back.
private struct WeekStrip: View {
    let now: Date
    let events: [EKEvent]
    let pitch: CGFloat
    @Binding var picked: Date?

    var body: some View {
        let cal = Calendar.current
        let days = cal.dateInterval(of: .weekOfYear, for: now).map { week in
            (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: week.start) }
        } ?? []
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in cell(day, cal: cal) }
        }
    }

    private func cell(_ day: Date, cal: Calendar) -> some View {
        let isToday = cal.isDate(day, inSameDayAs: now)
        let isPicked = !isToday && picked.map { cal.isDate($0, inSameDayAs: day) } == true
        let weekend = cal.isDateInWeekend(day)
        let past = day < cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: day)!
        var colors: [Color] = []
        var seen = Set<String>()
        for event in events where event.startDate < end && event.endDate > day {
            guard let calendar = event.calendar, seen.insert(calendar.calendarIdentifier).inserted else { continue }
            colors.append(Color(nsColor: calendar.color))
        }
        return VStack(spacing: 1) {
            Text(isToday ? day.formatted(.dateTime.weekday(.abbreviated)).uppercased() : day.formatted(.dateTime.weekday(.narrow)))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(isToday || isPicked ? 0.85 : 0.4))
                .lineLimit(1)
                .fixedSize()
            Text(day, format: .dateTime.day())
                // Smaller in a narrow strip, where today's two bold digits ran wider than the column.
                .font(.system(size: isToday ? (pitch < 30 ? 16 : 19) : (pitch < 30 ? 14 : 15),
                              weight: isToday ? .bold : weekend ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(isToday ? Color(nsColor: .systemRed) : .white.opacity(past ? 0.3 : weekend || isPicked ? 1 : 0.6))
                .lineLimit(1)
                .fixedSize()
                .frame(height: 22)
            HStack(spacing: 2) {
                ForEach(colors.prefix(3).indices, id: \.self) { i in
                    Circle().fill(colors[i]).frame(width: 4, height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 3)
        .frame(width: pitch)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(isPicked ? 0.12 : 0)))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.small.animation) { picked = isToday ? nil : day }
        }
        .help(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
    }
}
