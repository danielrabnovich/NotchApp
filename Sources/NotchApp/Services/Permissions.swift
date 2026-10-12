import AppKit
import AVFoundation
import EventKit
import UserNotifications

/// Every macOS permission NotchApp can use: whether it's granted, what it unlocks, and how to
/// grant it. Checked without ever putting up a prompt; prompts only come from a Grant button.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    enum Kind: String, CaseIterable, Identifiable {
        case accessibility, screenRecording, files, calendar, finder, notifications, systemAudio, camera, fullDisk
        var id: String { rawValue }
    }

    enum Level: String { case essential = "Essential", recommended = "Recommended", optional = "Optional" }

    enum Status: Equatable { case granted, denied, notAsked }

    struct Info {
        let title: String
        let icon: String
        let tint: NSColor
        /// What it lets NotchApp do, in a line.
        let unlocks: String
        let level: Level
    }

    static func info(_ kind: Kind) -> Info {
        switch kind {
        case .accessibility:
            Info(title: "Accessibility", icon: "accessibility", tint: .systemBlue,
                 unlocks: "App actions, menu search, AI Commands on selected text, keyboard shortcuts and the volume HUD.",
                 level: .essential)
        case .screenRecording:
            Info(title: "Screen Recording", icon: "rectangle.dashed.badge.record", tint: .systemRed,
                 unlocks: "Ask about the window in front, and Summarize page or email. Nothing is saved.",
                 level: .recommended)
        case .files:
            Info(title: "Files & Folders", icon: "folder.fill", tint: .systemBlue,
                 unlocks: "Search finds files in Desktop, Documents, Downloads and cloud folders.",
                 level: .recommended)
        case .calendar:
            Info(title: "Calendar", icon: "calendar", tint: .systemRed,
                 unlocks: "Today on Home, meeting alerts and Join buttons, and adding events from Search.",
                 level: .recommended)
        case .finder:
            Info(title: "Finder", icon: "faceid", tint: .systemCyan,
                 unlocks: "Actions for the files selected in Finder, and emptying the Trash.",
                 level: .optional)
        case .notifications:
            Info(title: "Notifications", icon: "bell.badge.fill", tint: .systemRed,
                 unlocks: "A notification when a long search finishes while the notch is closed.",
                 level: .optional)
        case .systemAudio:
            Info(title: "System Audio", icon: "waveform", tint: .systemPink,
                 unlocks: "Per-app volume in the mixer, and a visualizer that moves with the music.",
                 level: .optional)
        case .camera:
            Info(title: "Camera", icon: "camera.fill", tint: .systemGreen,
                 unlocks: "The camera mirror, for a look at yourself before a call.",
                 level: .optional)
        case .fullDisk:
            Info(title: "Full Disk Access", icon: "internaldrive.fill", tint: .systemGray,
                 unlocks: "The Focus Glance (which Focus is on), and the Trash's size in the Cleaner.",
                 level: .optional)
        }
    }

    @Published private(set) var status: [Kind: Status] = [:]
    private var timer: Timer?
    private var watchers = 0

    var essentialsGranted: Bool { status[.accessibility] == .granted }

    /// Re-reads every status (cheap; none of these prompt).
    func refresh() {
        var s: [Kind: Status] = [:]
        s[.accessibility] = AXIsProcessTrusted() ? .granted : .notAsked
        s[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .notAsked
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: s[.calendar] = .granted
        case .denied, .restricted, .writeOnly: s[.calendar] = .denied
        default: s[.calendar] = .notAsked
        }
        let folders = FolderAccess.shared
        s[.files] = !folders.decided ? .notAsked : folders.missing.isEmpty ? .granted : .denied
        switch AppContext.automationPermission("com.apple.finder", ask: false) {
        case noErr: s[.finder] = .granted
        case OSStatus(errAEEventWouldRequireUserConsent): s[.finder] = .notAsked
        default: s[.finder] = .denied
        }
        switch AudioCapturePermission.status() {
        case .granted: s[.systemAudio] = .granted
        case .denied: s[.systemAudio] = .denied
        default: s[.systemAudio] = .notAsked
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: s[.camera] = .granted
        case .denied, .restricted: s[.camera] = .denied
        default: s[.camera] = .notAsked
        }
        // macOS never asks for this one, so it's on or not yet turned on.
        s[.fullDisk] = FocusMonitor.canRead ? .granted : .notAsked
        s[.notifications] = status[.notifications] ?? .notAsked
        if s != status { status = s }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let n: Status = switch settings.authorizationStatus {
            case .authorized, .provisional: .granted
            case .denied: .denied
            default: .notAsked
            }
            Task { @MainActor in
                if Permissions.shared.status[.notifications] != n { Permissions.shared.status[.notifications] = n }
            }
        }
    }

    /// Keeps statuses current while a list of them is on screen (they change in System Settings).
    func watch(_ on: Bool) {
        watchers += on ? 1 : -1
        if watchers > 0, timer == nil {
            // Folders are read once per showing (cloud ones can be slow); the rest every tick.
            if FolderAccess.shared.decided { Task { await FolderAccess.shared.recheck(); refresh() } }
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                MainActor.assumeIsolated { Permissions.shared.refresh() }
            }
        } else if watchers <= 0 {
            watchers = 0
            timer?.invalidate()
            timer = nil
        }
    }

    /// Asks macOS (the prompt), or opens the right page of System Settings when it's been turned down.
    func request(_ kind: Kind) {
        if status[kind] == .denied { return openSettings(kind) }
        switch kind {
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            openSettings(kind)
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings(kind) }
        case .calendar:
            CalendarManager.shared.requestAccess()
        case .files:
            Task { await FolderAccess.shared.recheck(); refresh() }
        case .finder:
            Task.detached {
                _ = AppContext.automationPermission("com.apple.finder", ask: true)
                await MainActor.run { Permissions.shared.refresh() }
            }
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task { @MainActor in Permissions.shared.refresh() }
            }
        case .systemAudio:
            AudioCapturePermission.request { _ in Task { @MainActor in Permissions.shared.refresh() } }
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { _ in Task { @MainActor in Permissions.shared.refresh() } }
        case .fullDisk:
            openSettings(kind)
        }
    }

    func openSettings(_ kind: Kind) {
        let anchor: String
        switch kind {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .calendar: anchor = "Privacy_Calendars"
        case .files: anchor = "Privacy_FilesAndFolders"
        case .finder: anchor = "Privacy_Automation"
        case .systemAudio: anchor = "Privacy_AudioCapture"
        case .camera: anchor = "Privacy_Camera"
        case .fullDisk: anchor = "Privacy_AllFiles"
        case .notifications:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
            return
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
