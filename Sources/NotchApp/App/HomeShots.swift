import AppKit
import EventKit
import SwiftUI

/// Debug (`homeshot <dir>`): music's size and a call for HomeView to show instead of the live ones.
struct HomeShot {
    enum Music: String, CaseIterable { case large, small, none }
    var music: Music
    var call: MeetingMonitor.Call?
}

/// Debug (`homeshot <dir>`): Home drawn offscreen in every state that changes its layout (music big,
/// small or gone; a birthday, a call bar, a busy day, no weather) at two widths, one PNG each plus a
/// contact sheet. Made-up events, birthdays and weather go in for each shot and the real ones are
/// read again after, so a sheet from before a change can be diffed against one from after.
@MainActor
enum HomeShots {
    struct Fixture {
        let name: String
        var birthdays: [Birthdays.Person] = []
        var call = false
        var weather = true
        var events: (EKEventStore, Date) -> [EKEvent]
    }

    /// Content size of an open Home: the 680-point notch less its insets, and a wider notch's.
    static let sizes: [CGSize] = [CGSize(width: 644, height: 144), CGSize(width: 704, height: 144)]

    private static var window: NSWindow?

    static func run(dir: String) {
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var shots: [(label: String, url: URL, fixture: Fixture, music: HomeShot.Music, size: CGSize)] = []
        for fixture in fixtures {
            for music in HomeShot.Music.allCases {
                for size in sizes {
                    let label = "\(fixture.name)-\(music.rawValue)-\(Int(size.width))"
                    shots.append((label, out.appendingPathComponent(label + ".png"), fixture, music, size))
                }
            }
        }
        var images: [(String, NSImage)] = []
        func next(_ i: Int) {
            guard i < shots.count else {
                // Read again rather than put back what was there: it may have still been loading.
                Birthdays.shared.preview(nil)
                TodayWeather.shared.preview(nil)
                Birthdays.shared.refreshIfStale(force: true)
                TodayWeather.shared.refreshIfStale(force: true)
                CalendarManager.shared.preview(events: nil)
                window?.orderOut(nil)
                window = nil
                writeSheet(images, to: out.appendingPathComponent("sheet.png"))
                return
            }
            let shot = shots[i]
            let now = Date()
            Birthdays.shared.preview(shot.fixture.birthdays)
            TodayWeather.shared.preview(.some(shot.fixture.weather ? weather(now) : nil))
            CalendarManager.shared.preview(events: shot.fixture.events(CalendarManager.shared.store, now))
            let call = shot.fixture.call
                ? MeetingMonitor.Call(app: "Zoom", bundleID: "us.zoom.xos", started: now.addingTimeInterval(-300), event: "Writers Meeting")
                : nil
            let view = NSHostingView(rootView: HomeView(shot: HomeShot(music: shot.music, call: call))
                .frame(width: shot.size.width, height: shot.size.height)
                .foregroundStyle(.white)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
                .notchEnvironment())
            view.frame = CGRect(origin: .zero, size: shot.size)
            let window = Self.window ?? NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 800, height: 200),
                                                 styleMask: .borderless, backing: .buffered, defer: false)
            Self.window = window
            window.setContentSize(shot.size)
            window.contentView = view
            window.orderBack(nil)
            // Long enough for onAppear, GeometryReader and TimelineView to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: shot.url) }
                    let image = NSImage(size: view.bounds.size)
                    image.addRepresentation(rep)
                    images.append((shot.label, image))
                }
                next(i + 1)
            }
        }
        next(0)
    }

    /// Every shot in a grid, a row per fixture, each labelled.
    private static func writeSheet(_ images: [(String, NSImage)], to url: URL) {
        let columns = HomeShot.Music.allCases.count * sizes.count
        let cell = CGSize(width: sizes.map(\.width).max()! + 20, height: sizes[0].height + 34)
        let rows = (images.count + columns - 1) / columns
        let size = CGSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows))
        let sheet = NSImage(size: size)
        sheet.lockFocus()
        NSColor(white: 0.25, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        for (i, (label, image)) in images.enumerated() {
            let x = CGFloat(i % columns) * cell.width + 10
            let top = size.height - CGFloat(i / columns) * cell.height
            (label as NSString).draw(at: CGPoint(x: x, y: top - 22), withAttributes: attributes)
            image.draw(in: CGRect(x: x, y: top - 28 - image.size.height, width: image.size.width, height: image.size.height))
        }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    private static func weather(_ now: Date) -> WeatherReport {
        let cal = Calendar.current
        let days = (0..<5).map { i in
            WeatherReport.Day(date: cal.date(byAdding: .day, value: i, to: cal.startOfDay(for: now))!,
                              code: [0, 3, 3, 61, 2][i], high: [20, 13, 17, 12, 15][i], low: [6, 4, 1, 5, 3][i], rainChance: [0, 10, 0, 70, 20][i])
        }
        return WeatherReport(place: "Test", unit: "°C", currentTemp: 14, feelsLike: 12, currentCode: 0, wind: 8,
                             windUnit: "km/h", humidity: 45, days: days, focusDay: 0)
    }

    /// Events on the hour (not relative to the second) so two sheets taken minutes apart match.
    private static func event(_ store: EKEventStore, _ title: String, hour: Date, from: Double, hours: Double,
                              allDay: Bool = false, location: String? = nil) -> EKEvent {
        let e = EKEvent(eventStore: store)
        e.title = title
        e.isAllDay = allDay
        e.startDate = allDay ? Calendar.current.startOfDay(for: hour) : hour.addingTimeInterval(from * 3600)
        e.endDate = allDay ? Calendar.current.date(byAdding: .day, value: 1, to: e.startDate)! : e.startDate.addingTimeInterval(hours * 3600)
        e.location = location
        e.calendar = store.defaultCalendarForNewEvents
        return e
    }

    /// On the Birthdays calendar, as Contacts' birthdays are (the default calendar without one).
    private static func birthday(_ store: EKEventStore, _ title: String, _ now: Date) -> EKEvent {
        let e = event(store, title, hour: now, from: 0, hours: 0, allDay: true)
        if let birthdays = store.calendars(for: .event).first(where: { $0.type == .birthday }) { e.calendar = birthdays }
        return e
    }

    private static func hour(_ now: Date) -> Date {
        Calendar.current.dateInterval(of: .hour, for: now)!.start
    }

    static let fixtures: [Fixture] = [
        Fixture(name: "day") { store, now in
            [event(store, "Writers Meeting", hour: hour(now), from: 0, hours: 1.5),
             event(store, "Dinner", hour: hour(now), from: 2, hours: 1)]
        },
        Fixture(name: "birthday", birthdays: [.init(id: "1", name: "Марина", turning: 42)]) { store, now in
            [birthday(store, "Марина’s 42nd Birthday", now),
             event(store, "Writers Meeting", hour: hour(now), from: 0, hours: 1.5)]
        },
        Fixture(name: "birthday-call", birthdays: [.init(id: "1", name: "Марина", turning: 42)], call: true) { store, now in
            [birthday(store, "Марина’s 42nd Birthday", now),
             event(store, "Writers Meeting", hour: hour(now), from: 0, hours: 1.5)]
        },
        Fixture(name: "busy",
                birthdays: [.init(id: "1", name: "Alexandria Konstantinopoulou", turning: 30), .init(id: "2", name: "Марина", turning: 42)],
                call: true) { store, now in
            [birthday(store, "Марина’s 42nd Birthday", now),
             event(store, "Quarterly planning with the extended leadership team", hour: hour(now), from: 0, hours: 1,
                   location: "Conference Room 4B, North Building, Floor 12"),
             event(store, "Writers Meeting", hour: hour(now), from: 1, hours: 1.5),
             event(store, "Dentist", hour: hour(now), from: 3, hours: 1, location: "Dr. Weiß"),
             event(store, "Call with Konstantin", hour: hour(now), from: 4, hours: 0.5),
             event(store, "Gym", hour: hour(now), from: 5, hours: 1)]
        },
        Fixture(name: "noweather", weather: false) { store, now in
            [event(store, "Writers Meeting", hour: hour(now), from: 0, hours: 1.5)]
        },
        Fixture(name: "empty") { _, _ in [] },
    ]
}
