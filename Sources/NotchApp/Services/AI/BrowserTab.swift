import Foundation

/// A browser's front tab, asked through the browser's own scripting: Recall's way to a page's
/// address where the browser keeps it from Accessibility (Chrome, Vivaldi and the rest built on
/// Chromium), and to whether the window is incognito. macOS asks once per browser before the first
/// answer; a browser the user said no to isn't asked again until NotchApp is relaunched.
enum BrowserTab {
    struct Tab: Sendable {
        let url: String
        let isPrivate: Bool
    }

    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.vivaldi.Vivaldi", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "company.thebrowser.dia", "com.operasoftware.Opera",
    ]
    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var refused: Set<String> = []

    static func knows(_ bundleID: String) -> Bool { chromium.contains(bundleID) || safari.contains(bundleID) }

    /// The front window's tab, or nil (not a browser, no window, not allowed, or too slow). Blocks
    /// for up to a couple of seconds: off the main thread.
    static func front(_ bundleID: String) -> Tab? {
        guard knows(bundleID), !lock.withLock({ refused.contains(bundleID) }) else { return nil }
        // Only IDs from the lists above go into the script.
        let tab = safari.contains(bundleID) ? "URL of current tab of front window" : "URL of active tab of front window"
        let script = """
        with timeout of 2 seconds
            try
                tell application id "\(bundleID)"
                    if (count of windows) is 0 then return ""
                    set u to \(tab)
                    set m to "normal"
                    try
                        set m to mode of front window
                    end try
                    return u & linefeed & m
                end tell
            on error number n
                return "error " & n
            end try
        end timeout
        """
        let out = Shell.runSync("/usr/bin/osascript", ["-e", script], timeout: 3).out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("error ") {
            // -1743: the user said no (System Settings → Privacy & Security → Automation turns it back on).
            if out == "error -1743" { lock.withLock { _ = refused.insert(bundleID) } }
            DebugHooks.log("BrowserTab: \(bundleID) \(out)")
            return nil
        }
        let parts = out.components(separatedBy: "\n")
        guard let url = parts.first, !url.isEmpty else { return nil }
        return Tab(url: url, isPrivate: parts.count > 1 && parts[1] == "incognito")
    }
}
