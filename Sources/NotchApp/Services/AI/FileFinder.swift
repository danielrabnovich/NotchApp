import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct FileHit: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let url: URL
    var reason: String?
}

/// Finds a file from a vague description:
/// 1. the router has already turned the request into keywords + soft hints (type, date, people),
/// 2. several narrow Spotlight queries over the user's own folders gather candidates,
/// 3. candidates are scored locally (name matches, type/date hints), then
/// 4. the model reads a short description of the best dozen and picks the matches (skipped without a model).
enum FileFinder {
    struct Plan: Sendable {
        var keywords: [String] = []
        var kinds: [String] = []
        var daysAgoMax: Int?
        var people: [String] = []
        /// They're describing what a picture shows ("a person at a desk with a card game").
        var visual = false
    }

    struct Candidate: Sendable {
        let url: URL
        var score: Double
        var info = ""
        /// Whether MobileCLIP thinks the picture looks like the description "strongly" or "somewhat".
        var lookalike: String?
        var similarity: Float?
    }

    /// What's left after the first results, so more can be found while those are browsed.
    struct More: Sendable {
        let description: String
        let plan: Plan
        /// Candidates the model hasn't judged yet, best first.
        let remaining: [Candidate]
        /// Already showing.
        let shown: [URL]
        /// Pictures the model passed over, kept for the end of the list.
        let leftovers: [FileHit]
        /// Every picture the model has already been shown, so the next batch doesn't repeat any.
        var looked: [URL] = []
    }

    /// About this many results in all, counting those found while browsing.
    static let resultTarget = 10

    static func find(_ description: String, plan: Plan, useAI: Bool = true,
                     progress: @escaping @Sendable (String) async -> Void) async throws -> (hits: [FileHit], confident: Bool, more: More?) {
        let clock = ContinuousClock.now
        DebugHooks.log("FileFinder plan: keywords=\(plan.keywords) kinds=\(plan.kinds) days=\(String(describing: plan.daysAgoMax)) people=\(plan.people)")

        await progress("Looking through your files")
        await FolderAccess.shared.ensure()
        var plan = plan
        if plan.keywords.isEmpty {
            plan.keywords = description.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init).filter { $0.count > 2 && !stopWords.contains($0.lowercased()) }
        }
        // A described scene wants pictures, not files that happen to share its words ("game", "table").
        if !plan.visual, looksLikeScene(description, kinds: plan.kinds) { plan.visual = true }
        // "image of the cubicle training manual opened", "photo of…": an image was asked for by name.
        if plan.kinds.contains(where: { $0 == "image" || $0 == "screenshot" }) { plan.visual = true }
        if plan.visual, !plan.kinds.contains(where: { $0 == "image" || $0 == "screenshot" }) { plan.kinds.append("image") }
        var candidates = gather(plan)
        mergeImageMatches(into: &candidates, plan: plan)
        mergeVisualMatches(into: &candidates, description: description, plan: plan)
        // A picture whose text is this very request is a screenshot of searching for it.
        let request = description.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if request.split(separator: " ").count >= 4 {
            candidates.removeAll { c in
                ImageIndexStore.shared.entry(c.url.path).map {
                    $0.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(request)
                } ?? false
            }
        }
        DebugHooks.log("FileFinder spotlight (\(ContinuousClock.now - clock)): \(candidates.count) candidates; top: \(candidates.prefix(8).map { "\($0.url.lastPathComponent)=\(String(format: "%.1f", $0.score))" })")
        guard !candidates.isEmpty else { return ([], false, nil) }

        // Without a model, the Spotlight score (name matches, type and date hints) is the ranking.
        guard useAI else { return (candidates.prefix(resultTarget).map { FileHit(url: $0.url, reason: nil) }, false, nil) }

        // Describing a picture: let a model that can see look at the best few pictures itself. Labels
        // and CLIP can't tell "a person at a desk with a card game" from a game card in a "desk" folder.
        if plan.visual, await OllamaClient.supportsVision() {
            let pictures = pictureShortlist(candidates)
            if !pictures.isEmpty {
                await progress("Looking at \(pictures.count) pictures")
                var seen: [FileHit] = []
                do { seen = try await lookAt(description, pictures) } catch { DebugHooks.log("FileFinder lookAt failed: \(error)") }
                DebugHooks.log("FileFinder showed the model \(pictures.map(\.url.lastPathComponent)) → \(seen.map(\.url.lastPathComponent))")
                if !seen.isEmpty {
                    DebugHooks.log("FileFinder looked (\(ContinuousClock.now - clock)): \(seen.map(\.url.lastPathComponent))")
                    // A few of the rest to browse at the end, the ones that look most like it first.
                    let others = pictures.filter { p in !seen.contains { $0.url == p.url } }
                        .sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
                        .prefix(3)
                        .map { FileHit(url: $0.url, reason: nil) }
                    let shown = Set(pictures.map(\.url))
                    let more = More(description: description, plan: plan, remaining: candidates.filter { !shown.contains($0.url) },
                                    shown: seen.map(\.url), leftovers: Array(others), looked: pictures.map(\.url))
                    return (seen, true, more)
                }
            }
        }

        let top = Array(candidates.prefix(12))
        await progress("Reading \(top.count) likely matches")
        let described = top.map { c -> Candidate in
            var c = c
            c.info = describe(c.url)
            if let lookalike = c.lookalike { c.info += "\nlooks like the description: \(lookalike)" }
            return c
        }

        await progress("Picking the best one")
        let ranked = try? await rank(description, described, visual: plan.visual)
        DebugHooks.log("FileFinder ranked (\(ContinuousClock.now - clock)): \(ranked?.map(\.url.lastPathComponent) ?? [])")
        if let ranked, !ranked.isEmpty {
            let hits = Array((ranked + related(to: ranked, from: described, plan: plan)).prefix(resultTarget))
            let judged = Set(top.map(\.url))
            let more = hits.count < resultTarget && candidates.count > top.count
                ? More(description: description, plan: plan, remaining: candidates.filter { !judged.contains($0.url) },
                       shown: hits.map(\.url), leftovers: [])
                : nil
            return (hits, true, more)
        }
        return (described.prefix(5).map { FileHit(url: $0.url, reason: nil) }, false, nil)
    }

    /// The next batch, judged while the first results are browsed: pictures the model hasn't seen
    /// yet, or the next dozen candidates. Returns what to add to the end of the list.
    static func more(_ more: More) async -> [FileHit] {
        let room = resultTarget - more.shown.count
        guard room > 0 else { return [] }
        let shown = Set(more.shown)
        var found: [FileHit] = []
        if more.plan.visual {
            let lookedNames = Set((more.shown + more.looked).map { $0.deletingPathExtension().lastPathComponent.lowercased() })
            // Photos from the same folder as a match first: shots taken together (IMG_0665, 0666, 0667)
            // are often the next thing wanted.
            let isNew = { (url: URL) in !lookedNames.contains(url.deletingPathExtension().lastPathComponent.lowercased()) }
            let fresh = more.remaining.filter { isNew($0.url) }
            var nearbyURLs: [URL] = []
            for match in more.shown {
                for url in ImageIndexStore.shared.neighbors(of: match, limit: 3) where isNew(url) && !nearbyURLs.contains(url) {
                    nearbyURLs.append(url)
                }
            }
            let nearby = nearbyURLs.prefix(3).map { url in
                fresh.first { $0.url == url }.map { c -> Candidate in var c = c; c.score += 100; return c }
                    ?? Candidate(url: url, score: 100)
            }
            let taken = Set(nearby.map(\.url))
            let pictures = pictureShortlist(nearby + fresh.filter { !taken.contains($0.url) })
            // Extras, not the answer: only ones the model is fairly sure of.
            if !pictures.isEmpty, let seen = try? await lookAt(more.description, pictures, minConfidence: 0.5) {
                found = seen.filter { !shown.contains($0.url) }
                DebugHooks.log("FileFinder more: showed \(pictures.map(\.url.lastPathComponent)) → \(found.map(\.url.lastPathComponent))")
            }
        } else {
            let batch = more.remaining.prefix(12).map { c -> Candidate in
                var c = c
                c.info = describe(c.url)
                if let lookalike = c.lookalike { c.info += "\nlooks like the description: \(lookalike)" }
                return c
            }
            if !batch.isEmpty, let ranked = try? await rank(more.description, Array(batch), visual: false) {
                found = ranked.filter { !shown.contains($0.url) }
                DebugHooks.log("FileFinder more: ranked \(batch.count) → \(found.map(\.url.lastPathComponent))")
            }
        }
        let leftovers = more.leftovers.filter { l in !shown.contains(l.url) && !found.contains { $0.url == l.url } }
        return Array((found + leftovers).prefix(room))
    }

    /// Fast name-only matches for results-as-you-type: every word must be in the file name.
    /// Recently used files first.
    static func quickMatches(_ text: String, limit: Int) -> [URL] {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 2 && !stopWords.contains($0) }
        guard !words.isEmpty else { return [] }
        let query = words.prefix(4).map { "kMDItemDisplayName == \"*\($0)*\"cd" }.joined(separator: " && ")
        let urls = mdfind(query, limit: 40)
        func lastUsed(_ url: URL) -> Date {
            let item = NSMetadataItem(url: url)
            return item?.value(forAttribute: "kMDItemLastUsedDate") as? Date
                ?? item?.value(forAttribute: "kMDItemContentModificationDate") as? Date ?? .distantPast
        }
        // Names that start with the first word rank above names that merely contain it.
        let first = words[0]
        let byName = urls.map { ($0, lastUsed($0), $0.lastPathComponent.lowercased().hasPrefix(first)) }
            .sorted { $0.2 != $1.2 ? $0.2 : $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
        guard byName.count < limit else { return byName }
        // Then pictures of what was typed: every word matches what's in them, or the picture clearly
        // looks like the text.
        let labelled = ImageIndexStore.shared.search(words, limit: limit, strict: true).map(\.url)
        let lookalikes = ImageIndexStore.shared.visualSearch(text, limit: limit, strongOnly: true).map(\.url)
        var pictures: [URL] = []
        for url in lookalikes + labelled where !byName.contains(url) && !pictures.contains(url) { pictures.append(url) }
        return Array((byName + pictures).prefix(limit))
    }

    /// Adds pictures that MobileCLIP thinks look like the description, in the user's own words.
    private static func mergeVisualMatches(into candidates: inout [Candidate], description: String, plan: Plan) {
        let wantsImages = plan.kinds.contains { $0 == "image" || $0 == "screenshot" }
        guard plan.kinds.isEmpty || wantsImages else { return }
        // Asked for a picture: CLIP's best few count even when none stands out much.
        let hits = ImageIndexStore.shared.visualSearch(description, limit: plan.visual ? 8 : 10, relaxed: plan.visual)
        guard !hits.isEmpty else { return }
        var byPath = Dictionary(candidates.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        for hit in hits {
            var c = byPath[hit.url.path, default: Candidate(url: hit.url, score: 0)]
            var strength = max(Double(hit.standout - 3) * 2.5, Double(hit.similarity - 0.2) * 60)
            if plan.visual { strength = max(strength, Double(hit.similarity - 0.1) * 40) }
            c.score += max(strength, 1) * (wantsImages ? 1.5 : 1)
            c.lookalike = hit.isStrong ? "strongly" : hit.isPlausible ? "somewhat" : "loosely"
            c.similarity = hit.similarity
            byPath[hit.url.path] = c
        }
        candidates = byPath.values.sorted { $0.score > $1.score }
    }

    /// Adds images whose content matches the keywords (see ImageIndex), unless a non-image type was asked for.
    private static func mergeImageMatches(into candidates: inout [Candidate], plan: Plan) {
        let wantsImages = plan.kinds.contains { $0 == "image" || $0 == "screenshot" }
        guard plan.kinds.isEmpty || wantsImages else { return }
        // A described scene is about what's pictured, not words printed in the picture.
        let hits = ImageIndexStore.shared.search(plan.keywords, limit: 30, textWeight: plan.visual ? 2 : 3.5)
        guard !hits.isEmpty else { return }
        let cutoff = plan.daysAgoMax.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        var byPath = Dictionary(candidates.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        for hit in hits {
            var score = hit.score * (wantsImages ? 1.5 : 1)
            if let cutoff, hit.modified >= cutoff { score += 2 }
            byPath[hit.url.path, default: Candidate(url: hit.url, score: 0)].score += score
        }
        candidates = byPath.values.sorted { $0.score > $1.score }
    }

    /// Whether a request describes a scene rather than a document, for when the model didn't say:
    /// "a person at a desk with a card game on the table", "dog on the beach". Document words or a
    /// non-image type rule it out.
    static func looksLikeScene(_ text: String, kinds: [String]) -> Bool {
        guard kinds.allSatisfy({ $0 == "image" || $0 == "screenshot" }) else { return false }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let set = Set(words)
        let documents: Set<String> = ["file", "files", "document", "doc", "docs", "pdf", "resume", "cv", "contract", "invoice",
                                      "report", "essay", "assignment", "homework", "notes", "slides", "deck", "spreadsheet",
                                      "agreement", "lease", "form", "letter", "draft", "template", "sheet", "chapter"]
        guard set.isDisjoint(with: documents) else { return false }
        let relations: Set<String> = ["at", "on", "with", "in", "by", "near", "under", "over", "behind", "beside", "next",
                                      "holding", "wearing", "sitting", "standing", "playing", "eating", "riding", "smiling"]
        let subjects: Set<String> = ["person", "people", "man", "woman", "men", "women", "guy", "girl", "boy", "kid", "kids",
                                     "child", "baby", "someone", "me", "us", "friends", "family", "group", "dog", "cat", "car",
                                     "beach", "sunset", "mountain", "mountains", "lake", "ocean", "city", "street", "room",
                                     "desk", "table", "kitchen", "office", "sky", "snow", "food", "plate"]
        let describesSomething = ["a", "an", "two", "three", "some"].contains(words.first ?? "") && words.count >= 4
        return !set.isDisjoint(with: relations) && (describesSomething || !set.isDisjoint(with: subjects))
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
            // A keyword in the folders above counts too: "UGCA Contracts/Countersigned/UGCA - Gage Austin.pdf".
            let folders = c.url.deletingLastPathComponent().path.dropFirst(NSHomeDirectory().count).lowercased()
            if !plan.visual { c.score += Double(textWords.filter { !name.contains($0) && folders.contains($0) }.count) * 1.5 }
            // Source code only when asked for: "contracts.ts" isn't anyone's contract.
            if !plan.kinds.contains("code"), codeExtensions.contains(c.url.pathExtension.lowercased()) { c.score -= 4 }

            if let item = NSMetadataItem(url: c.url) {
                let tree = item.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
                if !wantedTypes.isEmpty, !wantedTypes.isDisjoint(with: tree) { c.score += 2.5 }
                if plan.visual, !tree.contains("public.image") { c.score -= 6 }
                if plan.kinds.contains("screenshot"), (item.value(forAttribute: "kMDItemIsScreenCapture") as? Bool) == true { c.score += 3 }
                if tree.contains("public.source-code"), !plan.kinds.contains("code"),
                   !codeExtensions.contains(c.url.pathExtension.lowercased()) { c.score -= 4 }
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

    static func isInteresting(_ path: String) -> Bool {
        // The user's own files only: skip app data (but keep iCloud Drive), code checkouts and caches.
        let library = NSHomeDirectory() + "/Library/"
        // …except iCloud Drive and cloud folders (Dropbox, Google Drive, OneDrive, Nextcloud…).
        if path.hasPrefix(library), !path.contains("/Mobile Documents/com~apple~CloudDocs/"),
           !path.hasPrefix(library + "CloudStorage/") { return false }
        let skip = ["/node_modules/", "/.git/", "/.build/", "/DerivedData/", ".app/", "/Caches/", "/__pycache__/",
                    "/venv/", "/.venv/", "/site-packages/", "/.npm/", "/.cache/", "/Pods/", "/vendor/", "/dist/", "/build/",
                    "/target/debug/", "/target/release/", "/.next/", "/.svelte-kit/", "/.turbo/", "/coverage/"]
        let url = URL(fileURLWithPath: path)
        return !skip.contains { path.contains($0) } && !path.contains("/.") && !url.lastPathComponent.hasPrefix("~$")
            && !buildExtensions.contains(url.pathExtension.lowercased())
    }

    /// Compiler and build leftovers nobody searches for by description.
    private static let buildExtensions: Set<String> = ["o", "d", "rmeta", "rlib", "pyc", "class", "map", "tsbuildinfo", "lock", "dylib", "a"]
    private static let codeExtensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "rs", "go", "py", "swift", "java", "kt",
                                                      "c", "h", "cpp", "hpp", "m", "rb", "php", "cs", "svelte", "vue", "astro", "css",
                                                      "scss", "sh", "toml", "yaml", "yml"]

    /// After the model's picks: a few more strong candidates to arrow through, e.g. Gage's contract
    /// first, then other contracts and the "UGCA Contracts" folder. Only ones that match a keyword by
    /// name or folder and scored at least half as well as the best.
    private static func related(to picks: [FileHit], from candidates: [Candidate], plan: Plan) -> [FileHit] {
        let picked = Set(picks.map(\.url))
        let words = plan.keywords.map { $0.lowercased() }.filter { $0.count >= 3 }
        guard let best = candidates.first?.score, best > 0 else { return [] }
        return candidates.filter { c in
            guard !picked.contains(c.url), c.score >= best * 0.5 else { return false }
            // A picture search only adds more pictures.
            if plan.visual { return c.lookalike != nil || ImageIndexStore.shared.entry(c.url.path) != nil }
            // Whole words (or their start): "contract" matches "Contracts", "gage" doesn't match "Mortgage".
            let tokens = c.url.path.dropFirst(NSHomeDirectory().count).lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return words.contains { word in tokens.contains { $0.hasPrefix(word) } }
        }
        .prefix(max(0, 6 - picks.count))
        .map { FileHit(url: $0.url, reason: nil) }
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
        lines += ImageIndexStore.shared.summary(url.path)
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

    /// The pictures worth showing the model: the best by score and the best by CLIP (which may score
    /// low on words), one per name so "card.png" and "card.webp" don't both take a slot.
    private static func pictureShortlist(_ candidates: [Candidate]) -> [Candidate] {
        let pictures = candidates.filter { isImage($0.url) }
        let byLook = pictures.filter { $0.similarity != nil }.sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
        var picked: [Candidate] = []
        var names = Set<String>()
        func take(_ list: [Candidate], upTo count: Int) {
            for c in list where picked.count < count {
                if names.insert(c.url.deletingPathExtension().lastPathComponent.lowercased()).inserted { picked.append(c) }
            }
        }
        take(pictures, upTo: 4)
        take(byLook, upTo: 7)
        take(pictures, upTo: 7)
        return picked
    }

    private static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Shows the pictures to the model (small JPEGs) and asks which fit the description; each match
    /// comes back with what the model saw in it.
    private static func lookAt(_ description: String, _ pictures: [Candidate], minConfidence: Double = 0.3) async throws -> [FileHit] {
        let images = pictures.compactMap { jpegThumbnail($0.url, maxPixels: 384) }
        guard images.count == pictures.count else { return [] }
        let system = """
        The user is looking for a picture on their Mac. You're shown pictures 0 to \(pictures.count - 1), in order. \
        Say in a few words what each one shows, then pick the ones that match the description, best first. \
        Leave out pictures that don't fit; an empty list is fine.
        Reply with JSON only: {"pictures": ["what picture 0 shows", ...], "matches": [{"index": number, "confidence": 0.0-1.0}]}
        """
        let obj = try await OllamaClient.chatJSON(system: system, user: "Looking for: \(description)", images: images)
        let seen = obj["pictures"] as? [String] ?? []
        var used = Set<Int>()
        return (obj["matches"] as? [[String: Any]] ?? []).compactMap { m in
            guard let i = (m["index"] as? NSNumber)?.intValue, pictures.indices.contains(i), used.insert(i).inserted,
                  ((m["confidence"] as? NSNumber)?.doubleValue ?? 1) >= minConfidence else { return nil }
            // "Picture 2: A young man…" → "A young man…"
            let said = seen.indices.contains(i) ? seen[i] : nil
            let reason = said.map { text -> String in
                let trimmed = text.replacingOccurrences(of: #"^\s*(Picture|Image)\s*\d+\s*([:.\-–]|shows|is)?\s*"#, with: "",
                                                        options: [.regularExpression, .caseInsensitive])
                return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
            }
            return FileHit(url: pictures[i].url, reason: reason)
        }
    }

    private static func jpegThumbnail(_ url: URL, maxPixels: Int) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func rank(_ description: String, _ candidates: [Candidate], visual: Bool) async throws -> [FileHit] {
        let list = candidates.enumerated().map { "[\($0.offset)]\n\($0.element.info)" }.joined(separator: "\n\n")
        let system = """
        You help the user find a file on their Mac. Given their description and numbered candidate files, \
        pick the files that match, best first (at most 5). A file whose name closely matches the description is usually right; for pictures, \
        "image shows" lists what's in them, "text in image" any text they contain, and "looks like the description" \
        means an image model compared the picture itself with the description. \
        Leave out anything that doesn't plausibly match; return an empty list if nothing does. \
        \(visual ? "They are describing what a picture shows: pick pictures whose content fits, judged by what the image shows, the text in it and how much it looks like the description. Names matter less here. A loose fit is still worth listing when nothing fits better. " : "")\
        Today is \(Date().formatted(date: .complete, time: .omitted)).
        Reply with JSON only: {"matches": [{"index": number, "confidence": 0.0-1.0, "reason": "under 10 words, why it matches"}]}
        """
        let obj = try await OllamaClient.chatJSON(system: system, user: "Description: \(description)\n\nCandidates:\n\n\(list)")
        let matches = obj["matches"] as? [[String: Any]] ?? []
        var seen = Set<Int>()
        return matches.compactMap { m in
            guard let i = (m["index"] as? NSNumber)?.intValue, candidates.indices.contains(i), seen.insert(i).inserted,
                  ((m["confidence"] as? NSNumber)?.doubleValue ?? 1) >= (visual ? 0.3 : 0.5) else { return nil }
            return FileHit(url: candidates[i].url, reason: m["reason"] as? String)
        }
    }
}
