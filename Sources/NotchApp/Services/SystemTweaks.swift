import AppKit
import Vision

/// Small system switches and one-shot utilities for the Controls tab and Search: hidden files,
/// desktop icons, Night Shift, flushing DNS and copying text off the screen.
@MainActor
final class SystemTweaks: ObservableObject {
    static let shared = SystemTweaks()

    @Published private(set) var hiddenFilesShown = false
    @Published private(set) var desktopIconsHidden = false
    @Published private(set) var nightShiftOn = false
    @Published private(set) var recognizing = false

    private init() {}

    func refresh() {
        hiddenFilesShown = Self.finderBool("AppleShowAllFiles") ?? false
        desktopIconsHidden = !(Self.finderBool("CreateDesktop") ?? true)
        nightShiftOn = NightShift.isEnabled ?? false
    }

    // MARK: - Finder

    func toggleHiddenFiles() {
        hiddenFilesShown.toggle()
        setFinder("AppleShowAllFiles", hiddenFilesShown)
        notice(hiddenFilesShown ? "Showing hidden files" : "Hiding hidden files", icon: hiddenFilesShown ? "eye" : "eye.slash")
    }

    func toggleDesktopIcons() {
        desktopIconsHidden.toggle()
        setFinder("CreateDesktop", !desktopIconsHidden)
        notice(desktopIconsHidden ? "Desktop icons hidden" : "Desktop icons shown", icon: "menubar.dock.rectangle")
    }

    nonisolated private static func finderBool(_ key: String) -> Bool? {
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        guard let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.finder" as CFString) else { return nil }
        if let b = value as? Bool { return b }
        if let s = value as? String { return ["1", "yes", "true"].contains(s.lowercased()) }
        return (value as? NSNumber)?.boolValue
    }

    /// Finder only reads these at launch, so it's relaunched (windows come back where they were).
    private func setFinder(_ key: String, _ value: Bool) {
        Task.detached {
            _ = await Shell.run("/usr/bin/defaults", ["write", "com.apple.finder", key, "-bool", value ? "true" : "false"])
            _ = await Shell.run("/usr/bin/killall", ["Finder"])
        }
    }

    // MARK: - Night Shift

    func toggleNightShift() {
        guard NightShift.isAvailable else {
            notice("Night Shift isn't available", icon: "moon.circle", tone: .warning)
            return
        }
        let on = !(NightShift.isEnabled ?? nightShiftOn)
        NightShift.setEnabled(on)
        nightShiftOn = on
        notice(on ? "Night Shift on" : "Night Shift off", icon: on ? "moon.circle.fill" : "moon.circle")
    }

    // MARK: - DNS

    func flushDNS() {
        Task {
            let ok = await Shell.runAsAdmin("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
            notice(ok ? "DNS cache flushed" : "DNS cache not flushed", icon: ok ? "arrow.clockwise.circle.fill" : "xmark.circle", tone: ok ? .success : .warning)
        }
    }

    // MARK: - Copy text from the screen

    /// Drag over any part of the screen; the text in it is copied.
    func copyTextFromScreen() {
        guard !recognizing else { return }
        recognizing = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notchapp-ocr-\(UUID().uuidString).png")
        Task {
            defer { recognizing = false }
            _ = await Shell.run("/usr/sbin/screencapture", ["-i", "-x", "-o", file.path], timeout: 120)
            defer { try? FileManager.default.removeItem(at: file) }
            guard FileManager.default.fileExists(atPath: file.path) else { return } // cancelled with Esc
            let text = await Self.recognizeText(in: file)
            guard let text, !text.isEmpty else {
                notice("No text found", detail: "Copy Text", icon: "text.viewfinder", tone: .warning)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let preview = text.replacingOccurrences(of: "\n", with: " ")
            notice("Copied \(text.split(whereSeparator: \.isWhitespace).count) words",
                   detail: String(preview.prefix(48)) + (preview.count > 48 ? "…" : ""), icon: "text.viewfinder")
        }
    }

    nonisolated static func recognizeText(in url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                let handler = VNImageRequestHandler(url: url)
                try? handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
        }
    }

    private func notice(_ title: String, detail: String = "Controls", icon: String, tone: NoticeTone = .success) {
        ActivityCenter.shared.show(.notice(title: title, detail: detail, icon: icon, tone: tone), for: 2.5)
    }
}

/// Night Shift through CoreBrightness's CBBlueLightClient, the same switch Control Center uses.
@MainActor
enum NightShift {
    private static let client: NSObject? = {
        Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load()
        guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    static var isAvailable: Bool {
        guard let client else { return false }
        return client.responds(to: NSSelectorFromString("setEnabled:"))
            && client.responds(to: NSSelectorFromString("getBlueLightStatus:"))
    }

    static var isEnabled: Bool? {
        guard let client, isAvailable else { return nil }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let fn = unsafeBitCast(client.method(for: sel), to: GetStatus.self)
        // struct { BOOL active; BOOL enabled; BOOL sunSchedulePermitted; int mode; … } – generously sized.
        let status = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
        defer { status.deallocate() }
        status.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        guard fn(client, sel, status) else { return nil }
        return status.load(fromByteOffset: 1, as: Bool.self)
    }

    static func setEnabled(_ on: Bool) {
        guard let client, isAvailable else { return }
        let sel = NSSelectorFromString("setEnabled:")
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(client.method(for: sel), to: SetEnabled.self)(client, sel, on)
    }
}
