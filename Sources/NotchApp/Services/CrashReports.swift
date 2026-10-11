import AppKit

/// NotchApp's crash reports, as macOS writes them (~/Library/Logs/DiagnosticReports). After a
/// crash, the next launch says so in the notch, with a short readable summary to copy (the
/// exception and the crashing thread) and the full report a click away. Nothing is sent anywhere.
@MainActor
enum CrashReports {
    struct Report: Identifiable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    private static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")

    /// Newest first.
    static func all() -> [Report] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("NotchApp-") && $0.pathExtension == "ips" }
            .compactMap { url in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Report(url: url, date: $0) }
            }
            .sorted { $0.date > $1.date }
    }

    /// At launch: a crash since the last look gets a Prompt. The first run only notes the time,
    /// so old reports don't come up.
    static func checkAtLaunch() {
        let defaults = UserDefaults.standard
        guard let seen = defaults.object(forKey: "crashReportsSeen") as? Date else {
            defaults.set(Date(), forKey: "crashReportsSeen")
            return
        }
        defaults.set(Date(), forKey: "crashReportsSeen")
        let fresh = all().filter { $0.date > seen }
        guard let latest = fresh.first else { return }
        let when = latest.date.formatted(date: .omitted, time: .shortened)
        NotchPresenter.shared.offer(Prompt(icon: "exclamationmark.triangle.fill", tint: .systemOrange,
                                           title: "NotchApp quit unexpectedly",
                                           detail: fresh.count == 1 ? "At \(when). The report stays on this Mac."
                                                                    : "\(fresh.count) times, last at \(when). The reports stay on this Mac.",
                                           actions: [.init(title: "Copy Summary", primary: true) { copySummary(latest) },
                                                     .init(title: "Show Report") { reveal(latest) }]),
                                    peek: true)
    }

    static func copySummary(_ report: Report) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary(report), forType: .string)
        ClipboardHistory.shared.ignoreCurrent()
        ActivityCenter.shared.show(.notice(title: "Copied crash summary", detail: report.url.lastPathComponent, icon: "doc.on.doc",
                                           tone: .success), for: 2.5)
    }

    static func reveal(_ report: Report) {
        NSWorkspace.shared.activateFileViewerSelecting([report.url])
    }

    /// What crashed, readably: when, which version, the exception, and the frames that matter.
    static func summary(_ report: Report) -> String {
        guard let raw = try? String(contentsOf: report.url, encoding: .utf8),
              let split = raw.firstIndex(of: "\n"),
              let head = try? JSONSerialization.jsonObject(with: Data(raw[..<split].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(raw[raw.index(after: split)...].utf8)) as? [String: Any]
        else { return "Couldn't read \(report.url.lastPathComponent)" }

        var lines = ["NotchApp \(head["app_version"] as? String ?? "?") crashed \(report.date.formatted())",
                     "\(head["os_version"] as? String ?? "")"]
        if let ex = body["exception"] as? [String: Any] {
            lines.append("Exception: \([ex["type"], ex["signal"], ex["subtype"]].compactMap { $0 as? String }.joined(separator: " · "))")
        }
        if let asi = body["asi"] as? [String: [String]] {
            for (_, messages) in asi { lines += messages.map { "Reason: \($0)" } }
        }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        func frames(_ list: [[String: Any]], limit: Int) -> [String] {
            list.prefix(limit).map { frame in
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "?"
                return "  \(image)  \(frame["symbol"] as? String ?? "0x" + String(frame["imageOffset"] as? Int ?? 0, radix: 16))"
            }
        }
        if let backtrace = body["lastExceptionBacktrace"] as? [[String: Any]], !backtrace.isEmpty {
            lines.append("Exception backtrace:")
            lines += frames(backtrace, limit: 20)
        }
        if let crashed = (body["threads"] as? [[String: Any]])?.first(where: { $0["triggered"] as? Bool == true }),
           let list = crashed["frames"] as? [[String: Any]] {
            lines.append("Crashed thread\((crashed["queue"] as? String).map { " (\($0))" } ?? ""):")
            lines += frames(list, limit: 20)
        }
        return lines.joined(separator: "\n")
    }
}
