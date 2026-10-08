import SwiftUI

/// Everything that can sit in the Controls tab's grid. Which ones show, and in what order, is
/// chosen in Settings → Controls.
enum ControlAction: String, CaseIterable, Codable, Identifiable {
    case wifi, keepAwake, darkMode, mic, screenshot, colorPicker, lockScreen, emptyTrash
    case copyText, ports, speedTest, cleaner, clipboard, hiddenFiles, desktopIcons, nightShift, flushDNS, saveVideo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .keepAwake: "Keep Awake"
        case .darkMode: "Dark Mode"
        case .mic: "Microphone"
        case .screenshot: "Screenshot"
        case .colorPicker: "Color Picker"
        case .lockScreen: "Lock Screen"
        case .emptyTrash: "Empty Trash"
        case .copyText: "Copy Text"
        case .ports: "Ports"
        case .speedTest: "Speed Test"
        case .cleaner: "Cleaner"
        case .clipboard: "Clipboard"
        case .hiddenFiles: "Hidden Files"
        case .desktopIcons: "Desktop Icons"
        case .nightShift: "Night Shift"
        case .flushDNS: "Flush DNS"
        case .saveVideo: "Save Video"
        }
    }

    var detail: String {
        switch self {
        case .wifi: "Turn Wi-Fi on or off."
        case .keepAwake: "Keep the Mac awake for a while."
        case .darkMode: "Switch between light and dark."
        case .mic: "Mute or unmute the microphone."
        case .screenshot: "Open the screenshot tool."
        case .colorPicker: "Copy the hex value of any color on screen."
        case .lockScreen: "Lock the Mac."
        case .emptyTrash: "Empty the Trash (click twice)."
        case .copyText: "Drag over any part of the screen to copy its text."
        case .ports: "See what's listening on which port, and stop it."
        case .speedTest: "Test your internet speed."
        case .cleaner: "Free up space (opens Tools)."
        case .clipboard: "Recent copies (opens the Shelf)."
        case .hiddenFiles: "Show or hide hidden files in Finder."
        case .desktopIcons: "Hide desktop icons, for screen sharing."
        case .nightShift: "Warmer colors."
        case .flushDNS: "Clear the DNS cache (asks for your password)."
        case .saveVideo: "Download the video link you copied, with yt-dlp."
        }
    }

    var icon: String {
        switch self {
        case .wifi: "wifi"
        case .keepAwake: "cup.and.saucer.fill"
        case .darkMode: "circle.lefthalf.filled"
        case .mic: "mic.fill"
        case .screenshot: "camera.viewfinder"
        case .colorPicker: "eyedropper"
        case .lockScreen: "lock.fill"
        case .emptyTrash: "trash.fill"
        case .copyText: "text.viewfinder"
        case .ports: "point.3.connected.trianglepath.dotted"
        case .speedTest: "speedometer"
        case .cleaner: "sparkles"
        case .clipboard: "doc.on.clipboard"
        case .hiddenFiles: "eye"
        case .desktopIcons: "menubar.dock.rectangle"
        case .nightShift: "moon.circle.fill"
        case .flushDNS: "arrow.clockwise.circle"
        case .saveVideo: "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .wifi: .blue
        case .keepAwake: .brown
        case .darkMode: Color(white: 0.35)
        case .mic: .red
        case .screenshot, .colorPicker: .purple
        case .lockScreen: .gray
        case .emptyTrash: Color(red: 1, green: 0.4, blue: 0.4)
        case .copyText: .teal
        case .ports: .indigo
        case .speedTest: .green
        case .cleaner: .pink
        case .clipboard: .orange
        case .hiddenFiles, .desktopIcons: Color(red: 0.35, green: 0.55, blue: 0.85)
        case .nightShift: Color(red: 1, green: 0.6, blue: 0.2)
        case .flushDNS: .cyan
        case .saveVideo: .red
        }
    }

    static let defaults: [ControlAction] = [.wifi, .keepAwake, .darkMode, .mic, .screenshot, .colorPicker, .lockScreen, .emptyTrash]
}

/// The tiles shown in the Controls tab, in order. Saved.
@MainActor
final class ControlTiles: ObservableObject {
    static let shared = ControlTiles()
    /// Two rows of six fit beside the sliders.
    static let limit = 12

    @Published var tiles: [ControlAction] {
        didSet { UserDefaults.standard.set(tiles.map(\.rawValue), forKey: "controlTiles") }
    }

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "controlTiles")
        tiles = saved.map { $0.compactMap(ControlAction.init(rawValue:)) } ?? ControlAction.defaults
    }

    var available: [ControlAction] { ControlAction.allCases.filter { !tiles.contains($0) } }
    var isFull: Bool { tiles.count >= Self.limit }

    func add(_ action: ControlAction) {
        guard !tiles.contains(action), !isFull else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { tiles.append(action) }
    }

    func remove(_ action: ControlAction) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { tiles.removeAll { $0 == action } }
    }

    /// Adds (or moves) an action to a position. Adding does nothing once the grid is full.
    func place(_ action: ControlAction, at index: Int) {
        guard tiles.contains(action) || !isFull else { return }
        var next = tiles.filter { $0 != action }
        next.insert(action, at: min(max(index, 0), next.count))
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { tiles = next }
    }

    func move(from source: IndexSet, to destination: Int) {
        tiles.move(fromOffsets: source, toOffset: destination)
    }

    func reset() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { tiles = ControlAction.defaults }
    }
}
