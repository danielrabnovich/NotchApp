import AppKit
import Darwin

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// Works out which app a process belongs to, so helpers ("Chrome Helper (Renderer)",
/// "com.docker.backend") show up under the app people recognise. Thread-safe.
enum AppIdentity {
    struct Info {
        var name: String
        /// The .app bundle, for its icon.
        var bundlePath: String?
        var bundleID: String?
    }

    /// The app that launched this process (itself if it is an app).
    static func responsiblePID(for pid: pid_t) -> pid_t {
        let owner = responsibility_get_pid_responsible_for_pid(pid)
        return owner > 0 ? owner : pid
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [pid_t: Info] = [:]

    /// Display name and bundle: the running app's own name, else the outermost .app the
    /// executable lives in, else the process name.
    static func of(pid: pid_t) -> Info {
        lock.lock()
        if let cached = cache[pid] { lock.unlock(); return cached }
        lock.unlock()

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : nil
        let bundle = path.flatMap { p in p.range(of: ".app/").map { String(p[..<$0.lowerBound]) + ".app" } }

        let info: Info
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            info = Info(name: name, bundlePath: app.bundleURL?.path ?? bundle, bundleID: app.bundleIdentifier)
        } else if let bundle {
            let b = Bundle(path: bundle)
            let name = b?.infoDictionary?["CFBundleDisplayName"] as? String ?? b?.infoDictionary?["CFBundleName"] as? String
            info = Info(name: name ?? URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent,
                        bundlePath: bundle, bundleID: b?.bundleIdentifier)
        } else {
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, 256)
            let name = String(cString: buffer)
            info = Info(name: name.isEmpty ? "pid \(pid)" : name)
        }
        lock.lock()
        cache[pid] = info
        lock.unlock()
        return info
    }

    /// Part of macOS itself: an executable on the read-only system volume (Siri's listener,
    /// dictation, corespeechd), bundled or not.
    static func isSystem(pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/"].contains { path.hasPrefix($0) }
    }

    /// Drops cached entries for processes that are gone (pids get reused).
    static func prune(keeping alive: Set<pid_t>) {
        lock.lock()
        cache = cache.filter { alive.contains($0.key) }
        lock.unlock()
    }
}
