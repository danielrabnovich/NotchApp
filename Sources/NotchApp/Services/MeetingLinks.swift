import AppKit
import EventKit

/// Finds the video-call link in a calendar event (Zoom, Google Meet, Teams, Webex, FaceTime…),
/// wherever the organiser put it: the URL field, the location or the notes.
enum MeetingLinks {
    struct Link {
        let url: URL
        /// "Zoom", "Meet", "Teams"…
        let service: String
    }

    private static let services: [(pattern: String, name: String)] = [
        (#"https://[\w.-]*zoom\.us/(j|my|w)/[^\s<>"']+"#, "Zoom"),
        (#"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s<>"']*"#, "Meet"),
        (#"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"']+"#, "Teams"),
        (#"https://teams\.live\.com/meet/[^\s<>"']+"#, "Teams"),
        (#"https://[\w.-]*webex\.com/[^\s<>"']+"#, "Webex"),
        (#"https://facetime\.apple\.com/join[^\s<>"']+"#, "FaceTime"),
        (#"https://whereby\.com/[^\s<>"']+"#, "Whereby"),
        (#"https://[\w.-]*slack\.com/huddle/[^\s<>"']+"#, "Slack"),
        (#"https://discord\.(gg|com)/[^\s<>"']+"#, "Discord"),
        (#"https://app\.gather\.town/[^\s<>"']+"#, "Gather"),
    ]

    static func find(in event: EKEvent) -> Link? {
        let texts = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for (pattern, name) in services {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for text in texts {
                let range = NSRange(text.startIndex..., in: text)
                if let m = regex.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                    // Notes often wrap links in angle brackets or end them with punctuation.
                    let raw = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>]"))
                    if let url = URL(string: raw) { return Link(url: url, service: name) }
                }
            }
        }
        return nil
    }

    /// Open the call: Zoom links go straight to the Zoom app when it's installed.
    static func join(_ link: Link) {
        if link.service == "Zoom", let zoom = zoomAppURL(link.url),
           NSWorkspace.shared.urlForApplication(toOpen: zoom) != nil {
            NSWorkspace.shared.open(zoom)
        } else {
            NSWorkspace.shared.open(link.url)
        }
    }

    /// https://us02web.zoom.us/j/123?pwd=abc → zoommtg://zoom.us/join?confno=123&pwd=abc
    private static func zoomAppURL(_ url: URL) -> URL? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.path.split(separator: "/").last, comps.path.contains("/j/") else { return nil }
        var app = URLComponents(string: "zoommtg://zoom.us/join")!
        app.queryItems = [URLQueryItem(name: "confno", value: String(id))]
            + (comps.queryItems?.filter { $0.name == "pwd" } ?? [])
        return app.url
    }
}
