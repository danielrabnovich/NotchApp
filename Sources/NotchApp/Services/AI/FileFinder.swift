import Foundation
import PDFKit

struct FileHit: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let url: URL
    var reason: String?
}

/// Finds a file from a vague description:
/// 1. the router has already turned the request into keywords + soft hints (type, date, people),
/// 2. several narrow Spotlight queries over the user's own folders gather candidates,
/// 3. candidates are scored locally (name matches, type/date hints), then
/// 4. the model reads a short description of the best dozen and picks the matches.
enum FileFinder {
    struct Plan: Sendable {
        var keywords: [String] = []
        var kinds: [String] = []
        var daysAgoMax: Int?
        var people: [String] = []
    }

    private struct Candidate {
        let url: URL
        var score: Double
        var info = ""
    }

    static func find(_ description: String, plan: Plan,
                     progress: @escaping @Sendable (String) async -> Void) async throws -> (hits: [FileHit], confident: Bool) {
        let clock = ContinuousClock.now
        DebugHooks.log("FileFinder plan: keywords=\(plan.keywords) kinds=\(plan.kinds) days=\(String(describing: plan.daysAgoMax)) people=\(plan.people)")

        await progress("Looking through your files")
        var plan = plan
        if plan.keywords.isEmpty {
            plan.keywords = description.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init).filter { $0.count > 2 && !stopWords.contains($0.lowercased()) }
        }
        let candidates = gather(plan)
        DebugHooks.log("FileFinder spotlight (\(ContinuousClock.now - clock)): \(candidates.count) candidates; top: \(candidates.prefix(8).map { "\($0.url.lastPathComponent)=\(String(format: "%.1f", $0.score))" })")
        guard !candidates.isEmpty else { return ([], false) }

        let top = Array(candidates.prefix(12))
        await progress("Reading \(top.count) likely matches")
        let described = top.map { c -> Candidate in var c = c; c.info = describe(c.url); return c }

        await progress("Picking the best one")
        let ranked = try? await rank(description, described)
        DebugHooks.log("FileFinder ranked (\(ContinuousClock.now - clock)): \(ranked?.map(\.url.lastPathComponent) ?? [])")
        if let ranked, !ranked.isEmpty { return (ranked, true) }
        return (described.prefix(5).map { FileHit(url: $0.url, reason: nil) }, false)
    }

    private static let stopWords: Set<String> = ["the", "and", "for", "from", "with", "that", "this", "my", "file", "files",
                                                  "document", "find", "where", "what", "about", "sent", "think", "was", "were"]

    // MARK: - Spotlight

    private static func gather(_ plan: Plan) -> [Candidate] {
        let words = plan.keywords.map { $0.lowercased() }
        let textWords = words.filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) }
        let numbers = words.filter { $0.allSatisfy(\.isNumber) }

        var queries: [(String, Double)] = []
        // Each keyword in the name: precise and fast.
        for w in textWords.prefix(6) {
            queries.append(("kMDItemDisplayName == \"*\(w)*\"cd", 3))
        }
        // The most distinctive words together in the text.
        let distinctive = textWords.sorted { $0.count > $1.count }.prefix(3)
        if distinctive.count >= 2 {
            queries.append((distinctive.map { "kMDItemTextContent == \"\($0)\"cdw" }.joined(separator: " && "), 4))
        }
        // Any keyword, narrowed by the type/date hints if there are any.
        let anyText = textWords.isEmpty ? nil : "(" + textWords.prefix(6).map {
            "kMDItemDisplayName == \"*\($0)*\"cd || kMDItemTextContent == \"\($0)\"cdw"
        }.joined(separator: " || ") + ")"
        let hints = [kindQuery(plan.kinds), dateQuery(plan.daysAgoMax)].compactMap { $0 }
        if let anyText, !hints.isEmpty {
            queries.append((([anyText] + hints).joined(separator: " && "), 3))
        } else if anyText == nil, !hints.isEmpty {
            queries.append((hints.joined(separator: " && "), 1))
        }
        for person in plan.people.prefix(2) {
            queries.append(("kMDItemAuthors == \"*\(person)*\"cd || kMDItemWhereFroms == \"*\(person)*\"cd || kMDItemTextContent == \"\(person)\"cdw", 2))
        }
        guard !queries.isEmpty else { return [] }

        var results = [[URL]](repeating: [], count: queries.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: queries.count) { i in
            let urls = mdfind(queries[i].0, limit: 80)
            lock.lock(); results[i] = urls; lock.unlock()
        }

        var byPath: [String: Candidate] = [:]
        for (i, urls) in results.enumerated() {
            for (rank, url) in urls.enumerated() {
                byPath[url.path, default: Candidate(url: url, score: 0)].score += queries[i].1 * (1 - Double(rank) / 120)
            }
        }

        // Local scoring: names, numbers, and the soft type/date hints.
        let cutoff = plan.daysAgoMax.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        let wantedTypes = Set(plan.kinds.flatMap { kindTypes[$0] ?? [] })
        for (path, var c) in byPath {
            let name = c.url.deletingPathExtension().lastPathComponent.lowercased()
            let tokens = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            c.score += Double(textWords.filter { name.contains($0) }.count) * 3
            for n in numbers { c.score += tokens.contains(n) ? 6 : -2 }

            if let item = NSMetadataItem(url: c.url) {
                let tree = item.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
                if !wantedTypes.isEmpty, !wantedTypes.isDisjoint(with: tree) { c.score += 2.5 }
                if plan.kinds.contains("screenshot"), (item.value(forAttribute: "kMDItemIsScreenCapture") as? Bool) == true { c.score += 3 }
                if tree.contains("public.source-code"), !plan.kinds.contains("code") { c.score -= 4 }
                if let cutoff {
                    let dates = ["kMDItemContentModificationDate", "kMDItemLastUsedDate", "kMDItemDateAdded"]
                        .compactMap { item.value(forAttribute: $0) as? Date }
                    if dates.contains(where: { $0 >= cutoff }) { c.score += 2 }
                }
            }
            byPath[path] = c
        }
        return byPath.values.filter { $0.score > 0 }.sorted { $0.score > $1.score }
    }

    private static func mdfind(_ query: String, limit: Int) -> [URL] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        // One scope is reliably fast; many -onlyin scopes can stall mdfind. Junk paths are filtered below.
        p.arguments = ["-onlyin", NSHomeDirectory(), query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        // mdfind prints nothing until it has every match; give up on a runaway query.
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            if p.isRunning { p.terminate(); DebugHooks.log("mdfind timed out: \(query.prefix(120))") }
        }
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        var urls: [URL] = []
        while urls.count < limit {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")), urls.count < limit {
                let path = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if isInteresting(path) { urls.append(URL(fileURLWithPath: path)) }
            }
        }
        if p.isRunning { p.terminate() }
        return urls
    }

    private static func isInteresting(_ path: String) -> Bool {
        // The user's own files only: skip app data (but keep iCloud Drive), code checkouts and caches.
        let library = NSHomeDirectory() + "/Library/"
        if path.hasPrefix(library), !path.contains("/Mobile Documents/com~apple~CloudDocs/") { return false }
        let skip = ["/node_modules/", "/.git/", "/.build/", "/DerivedData/", ".app/", "/Caches/", "/__pycache__/",
                    "/venv/", "/.venv/", "/site-packages/", "/.npm/", "/.cache/", "/Pods/", "/vendor/", "/dist/", "/build/"]
        let name = URL(fileURLWithPath: path).lastPathComponent
        return !skip.contains { path.contains($0) } && !path.contains("/.") && !name.hasPrefix("~$")
    }

    private static let kindTypes: [String: [String]] = [
        "pdf": ["com.adobe.pdf"],
        "word": ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages"],
        "excel": ["org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls", "public.comma-separated-values-text", "com.apple.iwork.numbers.sffnumbers"],
        "powerpoint": ["org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt", "com.apple.iwork.keynote.sffkey", "com.apple.keynote.key"],
        "image": ["public.image"],
        "screenshot": ["public.image"],
        "video": ["public.movie"],
        "audio": ["public.audio"],
        "text": ["public.plain-text", "net.daringfireball.markdown", "public.rtf"],
        "code": ["public.source-code"],
        "folder": ["public.folder"],
        "archive": ["public.archive"],
    ]

    private static func kindQuery(_ kinds: [String]) -> String? {
        var parts: [String] = []
        for kind in kinds {
            if kind == "screenshot" { parts.append("kMDItemIsScreenCapture == 1"); continue }
            for type in kindTypes[kind] ?? [] { parts.append("kMDItemContentTypeTree == \"\(type)\"") }
        }
        return parts.isEmpty ? nil : "(" + parts.joined(separator: " || ") + ")"
    }

    private static func dateQuery(_ days: Int?) -> String? {
        days.map { d in
            "(kMDItemContentModificationDate >= $time.today(-\(d)) || kMDItemLastUsedDate >= $time.today(-\(d)) || kMDItemDateAdded >= $time.today(-\(d)))"
        }
    }

    // MARK: - Rank

    /// A compact description of a file for the model: name, kind, dates, origin and a text preview.
    private static func describe(_ url: URL) -> String {
        var lines = ["name: \(url.lastPathComponent)", "folder: \(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"]
        if let item = NSMetadataItem(url: url) {
            if let kind = item.value(forAttribute: "kMDItemKind") as? String { lines.append("kind: \(kind)") }
            if let date = item.value(forAttribute: "kMDItemContentModificationDate") as? Date {
                lines.append("modified: \(date.formatted(date: .abbreviated, time: .omitted))")
            }
            if let froms = item.value(forAttribute: "kMDItemWhereFroms") as? [String], !froms.isEmpty {
                // Where-froms can be huge signed URLs; the site name is what matters.
                let hosts = froms.prefix(2).map { URL(string: $0)?.host() ?? String($0.prefix(40)) }
                lines.append("downloaded from: \(hosts.joined(separator: ", "))")
            }
            if let authors = item.value(forAttribute: "kMDItemAuthors") as? [String], !authors.isEmpty {
                lines.append("authors: \(authors.prefix(3).joined(separator: ", ").prefix(80))")
            }
        }
        if let preview = textPreview(url), !preview.isEmpty {
            lines.append("preview: \(preview)")
        }
        return String(lines.joined(separator: "\n").prefix(450))
    }

    private static func textPreview(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        var text: String?
        if ext == "pdf", let doc = PDFDocument(url: url) {
            text = (0..<min(2, doc.pageCount)).compactMap { doc.page(at: $0)?.string }.joined(separator: " ")
        } else if ["txt", "md", "markdown", "csv", "rtf", "json", "html", "tex"].contains(ext),
                  let handle = try? FileHandle(forReadingFrom: url) {
            let data = try? handle.read(upToCount: 2000)
            try? handle.close()
            text = data.map { String(decoding: $0, as: UTF8.self) }
        }
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(200))
    }

    private static func rank(_ description: String, _ candidates: [Candidate]) async throws -> [FileHit] {
        let list = candidates.enumerated().map { "[\($0.offset)]\n\($0.element.info)" }.joined(separator: "\n\n")
        let system = """
        You help the user find a file on their Mac. Given their description and numbered candidate files, \
        pick the files that match, best first (at most 5). A file whose name closely matches the description is usually right. \
        Leave out anything that doesn't plausibly match; return an empty list if nothing does. \
        Today is \(Date().formatted(date: .complete, time: .omitted)).
        Reply with JSON only: {"matches": [{"index": number, "confidence": 0.0-1.0, "reason": "under 10 words, why it matches"}]}
        """
        let obj = try await OllamaClient.chatJSON(system: system, user: "Description: \(description)\n\nCandidates:\n\n\(list)")
        let matches = obj["matches"] as? [[String: Any]] ?? []
        var seen = Set<Int>()
        return matches.compactMap { m in
            guard let i = (m["index"] as? NSNumber)?.intValue, candidates.indices.contains(i), seen.insert(i).inserted,
                  ((m["confidence"] as? NSNumber)?.doubleValue ?? 1) >= 0.5 else { return nil }
            return FileHit(url: candidates[i].url, reason: m["reason"] as? String)
        }
    }
}
