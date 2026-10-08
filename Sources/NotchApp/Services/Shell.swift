import Foundation

/// Runs command-line tools off the main thread.
enum Shell {
    struct Result {
        let code: Int32
        let out: String
        var ok: Bool { code == 0 }
    }

    /// Runs a tool and waits for it, with Homebrew on the PATH. Returns code -1 if it couldn't start.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 60) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(path, args, timeout: timeout))
            }
        }
    }

    static func runSync(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return Result(code: -1, out: "") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return Result(code: p.terminationStatus, out: String(data: data, encoding: .utf8) ?? "")
    }

    /// Runs a shell command as root after the standard macOS password prompt.
    static func runAsAdmin(_ command: String) async -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return await run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 300).ok
    }
}

/// Byte counts for people: "1.2 GB", "840 MB".
func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// A transfer rate in bytes per second as a short value and unit: ("12.4", "MB/s").
func formatRate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var v = max(0, bytesPerSecond)
    var i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
    let value = i == 0 ? "\(Int(v))" : v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    return (value, units[i])
}

/// Megabits per second, the way speed tests report them: "842", "48.2", "6.10".
func formatMbps(_ bitsPerSecond: Double) -> String {
    let m = bitsPerSecond / 1_000_000
    return m >= 100 ? String(format: "%.0f", m) : m >= 10 ? String(format: "%.1f", m) : String(format: "%.2f", m)
}
