import SwiftUI

// Colours that say what something is at a glance: where an answer came from, what a command does.
// The same few hues mean the same things everywhere (red for the calendar, orange for timers…).

extension AssistantStore.Route {
    var tint: Color {
        switch self {
        case .web: Color(red: 0.35, green: 0.65, blue: 1)
        case .files: .cyan
        case .weather: .yellow
        case .actions: .green
        case .calendar: Color(red: 1, green: 0.4, blue: 0.4)
        case .notes: Color(red: 1, green: 0.82, blue: 0.3)
        case .screen: .purple
        case .help: .mint
        case .recall: .indigo
        case .write: .orange
        case .app: .teal
        }
    }
}

extension Command {
    /// The colour of what this command does, or nil for plain navigation (opening a page, a link).
    var tint: Color? {
        switch action {
        case .addTasks, .completeTask: .green
        case .appendNote: Color(red: 1, green: 0.82, blue: 0.3)
        case .startTimer, .startPomodoro, .startStopwatch, .pauseTimer, .resumeTimer, .stopTimer: .orange
        case .keepAwake, .stopKeepAwake: .teal
        case .toggleDarkMode, .toggleNightShift: .indigo
        case .toggleWiFi, .speedTest, .flushDNS, .downloadMedia: Color(red: 0.35, green: 0.65, blue: 1)
        case .toggleMic, .setVolume, .media: .pink
        case .setBrightness: .yellow
        case .createEvent, .moveEvent: Color(red: 1, green: 0.4, blue: 0.4)
        case .quitApp, .deleteEvent, .emptyTrash, .uninstall, .stopPort, .lockScreen, .power: .red
        case .screenshot, .pickColor, .copyText, .copyClip: .purple
        case .translate, .transformClipboard, .aiCommand, .askScreen, .planFromScreen: .orange
        case .window: .cyan
        default: nil
        }
    }
}

extension ClipboardHistory.Clip.Kind? {
    /// Links blue, pictures purple, files cyan; text (and everything) stays white.
    var tint: Color? {
        switch self {
        case .link?: Color(red: 0.35, green: 0.65, blue: 1)
        case .image?: .purple
        case .files?: .cyan
        default: nil
        }
    }
}

extension WeatherReport {
    /// A temperature's colour: cold blue through mild green-yellow to hot red (judged in Celsius).
    func tint(_ temp: Double) -> Color {
        let c = unit.uppercased().contains("F") ? (temp - 32) * 5 / 9 : temp
        let stops: [(Double, (Double, Double, Double))] = [
            (-10, (0.55, 0.65, 1.0)), (0, (0.45, 0.8, 1.0)), (10, (0.5, 0.9, 0.8)),
            (18, (0.85, 0.92, 0.5)), (25, (1.0, 0.78, 0.35)), (32, (1.0, 0.5, 0.35)), (40, (1.0, 0.35, 0.4)),
        ]
        guard let upper = stops.firstIndex(where: { $0.0 >= c }) else { let t = stops.last!.1; return Color(red: t.0, green: t.1, blue: t.2) }
        guard upper > 0 else { let t = stops[0].1; return Color(red: t.0, green: t.1, blue: t.2) }
        let (t0, a) = stops[upper - 1], (t1, b) = stops[upper]
        let f = (c - t0) / (t1 - t0)
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }

    /// The colour a sky gives off: sunny gold, rainy blue, stormy violet, grey for cloud and fog.
    static func glow(_ code: Int) -> Color {
        switch code {
        case 0, 1: .yellow
        case 2: .orange
        case 51...67, 80...82: .blue
        case 71...77, 85, 86: .cyan
        case 95...99: .purple
        default: .gray
        }
    }
}

/// A day's low-to-high, as a short bar placed within the days' range and coloured cold to hot.
struct TempRange: View {
    let report: WeatherReport
    let low: Double
    let high: Double
    let coldest: Double
    let warmest: Double
    var width: CGFloat = 26

    var body: some View {
        let span = max(warmest - coldest, 1)
        let from = CGFloat((low - coldest) / span) * width
        let to = CGFloat((high - coldest) / span) * width
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.1))
            Capsule()
                .fill(LinearGradient(colors: [report.tint(low), report.tint(high)], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(to - from, 4))
                .offset(x: min(from, width - 4))
        }
        .frame(width: width, height: 4)
    }
}
