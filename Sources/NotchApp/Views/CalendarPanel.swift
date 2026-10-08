import EventKit
import SwiftUI

struct CalendarPanel: View {
    @EnvironmentObject private var calendar: CalendarManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Date.now, format: .dateTime.weekday(.wide))
                    .font(.system(size: 13, weight: .semibold))
                Text(Date.now, format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { calendar.openCalendar() }

            if !calendar.hasAccess {
                VStack(alignment: .leading, spacing: 8) {
                    Text("See today's events here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    Button("Allow Calendar Access") { calendar.requestAccess() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            } else if calendar.events.isEmpty {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text("Nothing else today")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(calendar.events, id: \.calendarItemIdentifier) { event in
                            EventRow(event: event)
                        }
                    }
                }
            }
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
