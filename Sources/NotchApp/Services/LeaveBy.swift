import CoreLocation
import EventKit
import MapKit

/// When to leave for the next event with a place: Apple Maps' driving time from where the Mac is
/// to the event's address (with traffic, as of now). The Next Event Glance counts down to leaving
/// instead of to the start, and a Banner says when it's time. Needs Location (Settings →
/// Permissions); without it, events count down to their start as before.
@MainActor
final class LeaveBy: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LeaveBy()

    struct Trip: Equatable {
        let eventID: String
        let travel: TimeInterval
        let leaveAt: Date
        let checked: Date
    }

    /// The trip to the next event with a place, when there is one.
    @Published private(set) var trip: Trip?
    @Published private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var here: CLLocation?
    private var alerted: Set<String> = []
    private var timer: Timer?
    private var working = false

    private override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var allowed: Bool { authorization == .authorizedAlways }

    func requestAccess() { manager.requestWhenInUseAuthorization() }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { LeaveBy.shared.tick() }
        }
        tick()
    }

    /// Minutes until leaving for an event, when its trip is known.
    func minutesToLeave(for event: EKEvent, now: Date = Date()) -> Int? {
        guard let trip, trip.eventID == event.eventIdentifier else { return nil }
        return Int(trip.leaveAt.timeIntervalSince(now) / 60)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            LeaveBy.shared.authorization = manager.authorizationStatus
            Permissions.shared.refresh()
            LeaveBy.shared.tick()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            LeaveBy.shared.here = location
            LeaveBy.shared.tick()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    /// The next event with a real place in the next three hours: the trip, worked out again every
    /// ten minutes (traffic changes); and the Banner once it's time to go.
    private func tick() {
        guard allowed, let event = Self.nextPlaced() else {
            if trip != nil { trip = nil }
            return
        }
        if let trip, trip.eventID == event.eventIdentifier {
            alertIfTime(trip, event)
            if Date().timeIntervalSince(trip.checked) < 600 { return }
        }
        guard !working else { return }
        // Where the Mac is, at most a quarter of an hour old.
        guard let here, Date().timeIntervalSince(here.timestamp) < 900 else {
            manager.requestLocation()
            return
        }
        working = true
        Task {
            defer { working = false }
            guard let destination = await Self.destination(of: event) else { return }
            let request = MKDirections.Request()
            request.source = Self.item(here)
            request.destination = destination
            request.transportType = .automobile
            request.departureDate = Date()
            guard let eta = try? await MKDirections(request: request).calculateETA() else { return }
            // Five minutes to get out of the door.
            let leave = event.startDate.addingTimeInterval(-eta.expectedTravelTime - 300)
            let new = Trip(eventID: event.eventIdentifier, travel: eta.expectedTravelTime, leaveAt: leave, checked: Date())
            trip = new
            alertIfTime(new, event)
        }
    }

    private func alertIfTime(_ trip: Trip, _ event: EKEvent) {
        guard Date() >= trip.leaveAt.addingTimeInterval(-60), Date() < event.startDate,
              alerted.insert(event.eventIdentifier).inserted else { return }
        let minutes = Int((trip.travel / 60).rounded())
        ActivityCenter.shared.show(.notice(title: "Time to leave for \(event.title ?? "your event")",
                                           detail: "\(minutes) min drive · starts \(event.startDate.formatted(date: .omitted, time: .shortened))",
                                           icon: "car.fill", tone: .info), for: 8)
    }

    /// The next timed event within three hours with a place you'd travel to (not a video call).
    static func nextPlaced(now: Date = Date()) -> EKEvent? {
        CalendarManager.shared.events
            .filter { !$0.isAllDay && $0.startDate > now && $0.startDate < now.addingTimeInterval(3 * 3600) }
            .filter { e in
                if e.structuredLocation?.geoLocation != nil { return true }
                guard let place = e.location?.trimmingCharacters(in: .whitespaces), place.count > 5 else { return false }
                let lower = place.lowercased()
                return !lower.contains("http") && !lower.contains("zoom") && !lower.contains("meet.google") && !lower.contains("teams")
                    && MeetingLinks.find(in: e) == nil
            }
            .min { $0.startDate < $1.startDate }
    }

    private static func item(_ location: CLLocation) -> MKMapItem {
        if #available(macOS 26, *) { return MKMapItem(location: location, address: nil) }
        return MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
    }

    private static func destination(of event: EKEvent) async -> MKMapItem? {
        if let geo = event.structuredLocation?.geoLocation {
            return item(geo)
        }
        guard let place = event.location else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place
        return try? await MKLocalSearch(request: request).start().mapItems.first
    }
}
