import AppKit
import Combine
import ImageIO
import Vision

/// Lets file search find pictures by what's in them. Images in the user's folders are run through
/// the Mac's built-in Vision models once (what the picture shows, plus any text in it), in the
/// background, and the results are kept in Application Support. Nothing leaves the Mac.
@MainActor
final class ImageIndex: ObservableObject {
    static let shared = ImageIndex()

    /// Images whose content is known.
    @Published private(set) var indexed = 0
    /// Images still to look at in the current pass.
    @Published private(set) var remaining = 0
    /// How many the current pass set out to look at, and when it started (for time left).
    @Published private(set) var passTotal = 0
    private var passStarted = Date()

    var isIndexing: Bool { remaining > 0 && passTotal > 0 }
    var passDone: Int { max(passTotal - remaining, 0) }
    var fraction: Double { passTotal > 0 ? Double(passDone) / Double(passTotal) : 0 }

    /// "about 6 min left", once enough pictures are done to tell.
    var timeLeft: String? {
        guard isIndexing, passDone >= 5 else { return nil }
        let seconds = Date().timeIntervalSince(passStarted) / Double(passDone) * Double(remaining)
        if seconds < 60 { return "under a minute left" }
        if seconds < 3600 { return "about \(Int((seconds / 60).rounded())) min left" }
        return "about \(Int((seconds / 3600).rounded())) h left"
    }

    private var task: Task<Void, Never>?
    /// Asked for while a pass was running (e.g. a folder just became readable): go again after it.
    private var again = false
    private var cancellables = Set<AnyCancellable>()

    func start() {
        Task.detached(priority: .utility) {
            ImageIndexStore.shared.load()
            // Folders macOS has already let us into can be read without a prompt; check them first
            // so the first pass covers them.
            if await FolderAccess.shared.decided { await FolderAccess.shared.ensure() }
            await MainActor.run {
                let s = AppSettings.shared
                self.indexed = ImageIndexStore.shared.count
                // The first pass waits a minute after launch, so it doesn't compete with logging in
                // (it can keep a core busy for a while); turning it on later starts at once.
                s.$imageIndexing.removeDuplicates()
                    .sink { on in DispatchQueue.main.async { on ? self.refresh() : self.pause() } }
                    .store(in: &self.cancellables)
                // A folder that becomes readable gets indexed right away.
                FolderAccess.shared.$access.dropFirst().removeDuplicates()
                    .sink { _ in DispatchQueue.main.async { self.refresh() } }
                    .store(in: &self.cancellables)
                NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                    .sink { _ in DispatchQueue.main.async { self.refresh() } }
                    .store(in: &self.cancellables)
                // New images are picked up on the next pass; passes over unchanged folders only stat files.
                Timer.publish(every: 600, on: .main, in: .common).autoconnect()
                    .sink { _ in self.refresh() }
                    .store(in: &self.cancellables)
            }
        }
    }

    private let launched = Date()

    func refresh() {
        guard AppSettings.shared.imageIndexing else { return }
        let wait = 60 - Date().timeIntervalSince(launched)
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.refresh() }
            return
        }
        guard task == nil else { again = true; return }
        again = false
        let folders = folders()
        let cloud = cloudFolders()
        // Utility, not background: background work is throttled hard enough on a busy Mac that a
        // photo took ~4s. Low Power Mode still pauses the pass.
        task = Task.detached(priority: .utility) {
            await ImageIndex.run(folders, cloud: cloud) { indexed, remaining in
                await MainActor.run {
                    let index = ImageIndex.shared
                    // The first report of a pass says how much there is to do.
                    if index.passTotal == 0 || remaining > index.passTotal {
                        index.passTotal = remaining
                        index.passStarted = Date()
                    }
                    index.indexed = indexed
                    index.remaining = remaining
                }
            }
            await MainActor.run {
                let index = ImageIndex.shared
                index.task = nil
                index.remaining = 0
                index.passTotal = 0
                if index.again { index.refresh() }
            }
        }
    }

    private func pause() {
        task?.cancel()
        task = nil
        again = false
        remaining = 0
        passTotal = 0
    }

    /// Pictures and the screenshot folder, plus Desktop, Documents and Downloads once macOS has let
    /// the app in (reading them sooner would put up permission prompts at launch).
    private func folders() -> [String] {
        let home = NSHomeDirectory()
        let protected = FolderAccess.shared.folders.map(\.path).filter { !$0.contains("/Library/") }
        let allowed = protected.filter { FolderAccess.shared.access[$0] == true }
        var list = ["\(home)/Pictures"] + allowed
        if let shots = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let path = (shots as NSString).expandingTildeInPath
            let blocked = protected.contains { path.hasPrefix($0) && !allowed.contains($0) }
            if !blocked { list.append(path) }
        }
        // Drop folders that sit inside another one on the list.
        return list.filter { p in !list.contains { $0 != p && p.hasPrefix($0 + "/") } }
    }

    /// iCloud Drive, Nextcloud, Dropbox… once macOS has let the app in. Their pictures are listed
    /// through Spotlight: walking a cloud folder makes its provider fetch every directory.
    private func cloudFolders() -> [String] {
        FolderAccess.shared.folders.map(\.path).filter { $0.contains("/Library/") && FolderAccess.shared.access[$0] == true }
    }

    // MARK: - Indexing (background)

    private nonisolated static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp"]
    private nonisolated static let maxImages = 25_000

    private nonisolated static func run(_ folders: [String], cloud: [String],
                                        progress: @escaping @Sendable (Int, Int) async -> Void) async {
        let store = ImageIndexStore.shared
        let files = scan(folders, cloud: cloud)
        store.prune(keeping: Set(files.keys))
        // Whether MobileCLIP is here, without loading it: most passes find nothing to do.
        let canEmbed = VisualSearch.isUsable
        // New or changed pictures, plus (once MobileCLIP is here) ones indexed before it was.
        // Newest first: those are the ones people look for.
        let todo = files.filter { path, modified in
            guard let entry = store.entry(path), entry.modified == modified else { return true }
            return canEmbed && entry.vector == nil && entry.readable
        }.sorted { $0.value > $1.value }
        DebugHooks.log("ImageIndex: \(files.count) images, \(todo.count) to index (clip: \(canEmbed))")
        await progress(store.count, todo.count)

        for (i, (path, modified)) in todo.enumerated() {
            if Task.isCancelled || ProcessInfo.processInfo.isLowPowerModeEnabled { break }
            let existing = store.entry(path).flatMap { $0.modified == modified ? $0 : nil }
            // Fetched per picture (not held for the pass) so it counts as in use, and a search
            // meanwhile shares this copy rather than loading a second one.
            let clip = canEmbed ? VisualSearch.model : nil
            let entry = autoreleasepool { analyze(URL(fileURLWithPath: path), modified: modified, existing: existing, clip: clip) }
            store.set(path, entry)
            if i % 5 == 4 { await progress(store.count, todo.count - i - 1) }
            if i % 50 == 49 { store.save() }
        }
        store.save()
        await progress(store.count, 0)
    }

    private nonisolated static let scanKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
                                                                  .ubiquitousItemDownloadingStatusKey]

    private nonisolated static func scan(_ folders: [String], cloud: [String]) -> [String: Date] {
        var found: [String: Date] = [:]
        func consider(_ url: URL) {
            guard extensions.contains(url.pathExtension.lowercased()), FileFinder.isInteresting(url.path),
                  let values = try? url.resourceValues(forKeys: Set(scanKeys)), values.isRegularFile == true,
                  // Icons and UI assets aren't worth it; nor are cloud files that would have to download first.
                  (values.fileSize ?? 0) >= 15_000,
                  values.ubiquitousItemDownloadingStatus == nil || values.ubiquitousItemDownloadingStatus == .current,
                  !isDataless(url.path)
            else { return }
            found[url.path] = values.contentModificationDate ?? .distantPast
        }
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: scanKeys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            // The walker's URLs (and their cached resource values) are autoreleased: drain them as
            // it goes, or a whole home folder's worth is held until the walk ends.
            while let url = autoreleasepool(invoking: { walker.nextObject() as? URL }) {
                autoreleasepool { consider(url) }
            }
        }
        for folder in cloud {
            spotlightImages(in: folder).forEach(consider)
        }
        guard found.count > maxImages else { return found }
        return Dictionary(uniqueKeysWithValues: found.sorted { $0.value > $1.value }.prefix(maxImages).map { ($0.key, $0.value) })
    }

    /// A cloud placeholder whose contents aren't on this Mac: reading it would download it.
    private nonisolated static func isDataless(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return true }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    private nonisolated static func spotlightImages(in folder: String) -> [URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", folder, "kMDItemContentTypeTree == \"public.image\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// What Vision (and MobileCLIP, when downloaded) sees in one image. Unreadable or tiny images get
    /// an empty entry so they aren't retried. With `existing`, Vision already ran: only the vector is added.
    private nonisolated static func analyze(_ url: URL, modified: Date, existing: ImageIndexStore.Entry?,
                                            clip: CLIPModel?) -> ImageIndexStore.Entry {
        var entry = existing ?? ImageIndexStore.Entry(modified: modified, labels: [:], text: "")
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        // CLIP looks at 256×256, so a vector-only pass decodes far less.
                                        kCGImageSourceThumbnailMaxPixelSize: existing == nil ? 1600 : 512]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              max(image.width, image.height) >= 200 else {
            entry.readable = false
            return entry
        }
        if let clip, let vector = try? clip.embed(image: image) { entry.setVector(vector) }
        guard existing == nil else { return entry }

        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        // Accurate reads screenshots well in a few hundred ms; automatic language detection made
        // the same screenshot take ~45s, so the system languages are used instead.
        text.recognitionLevel = .accurate
        do {
            try VNImageRequestHandler(cgImage: image).perform([classify, text])
        } catch {
            return entry
        }
        for label in (classify.results ?? []).filter({ $0.confidence >= 0.3 }).prefix(15) {
            entry.labels[label.identifier] = (label.confidence * 100).rounded() / 100
        }
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        entry.text = String(lines.joined(separator: " ").prefix(1500))
        return entry
    }
}

/// The index itself: read from file search on any thread, written by the indexer.
final class ImageIndexStore: @unchecked Sendable {
    static let shared = ImageIndexStore()

    struct Entry: Codable {
        var modified: Date
        /// Vision's labels (e.g. "dog", "sunset_sunrise") and how sure it is of each.
        var labels: [String: Float]
        /// Text found in the image.
        var text: String
        /// MobileCLIP's view of the picture: 512 values quantized to bytes, with their scale.
        var vector: Data?
        var vectorScale: Float?
        /// Tiny or undecodable images are remembered (so they aren't retried) but never vectorized.
        var unreadable: Bool?

        var readable: Bool {
            get { unreadable != true }
            set { unreadable = newValue ? nil : true }
        }

        mutating func setVector(_ values: [Float]) {
            let scale = max(values.map(abs).max() ?? 0, .leastNormalMagnitude) / 127
            vector = Data(values.map { UInt8(bitPattern: Int8(($0 / scale).rounded())) })
            vectorScale = scale
        }

        /// The vector back as unit-length floats.
        var floats: [Float]? {
            guard let vector, let vectorScale else { return nil }
            let values = vector.map { Float(Int8(bitPattern: $0)) * vectorScale }
            let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return norm > 0 ? values.map { $0 / norm } : nil
        }
    }

    struct VisualHit {
        let url: URL
        let similarity: Float
        /// How far above the other pictures this one stands (standard deviations). Real matches sit
        /// around 4–6; the best of nothing-relevant sits around 3.5–4.
        let standout: Float

        /// Similarity matters too: among many alike pictures (a folder of screenshots) the right one
        /// can't stand out, but real matches score 0.23+ and wrong ones stayed under ~0.21 in testing.
        var isStrong: Bool { standout >= 5 || similarity >= 0.28 }
        var isPlausible: Bool { standout >= 3.5 || similarity >= 0.25 }
    }

    struct Hit {
        let url: URL
        let score: Double
        let modified: Date
    }

    /// An entry plus its words, ready to match.
    private struct Indexed {
        let entry: Entry
        let labelWords: [String: Float]
        let textWords: Set<String>
        let vector: [Float]?

        init(_ entry: Entry) {
            self.entry = entry
            vector = entry.floats
            var words: [String: Float] = [:]
            for (label, confidence) in entry.labels {
                for word in label.split(separator: "_") {
                    let w = ImageIndexStore.stem(String(word))
                    words[w] = max(words[w] ?? 0, confidence)
                }
            }
            labelWords = words
            textWords = Set(ImageIndexStore.words(entry.text))
        }
    }

    private let lock = NSLock()
    private var items: [String: Indexed] = [:]
    private var dirty = false

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ImageIndex.json")
    }()

    var count: Int { lock.withLock { items.values.filter { !$0.entry.labels.isEmpty || !$0.entry.text.isEmpty }.count } }

    func load() {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        let loaded = entries.mapValues(Indexed.init)
        lock.withLock { items = loaded }
    }

    func save() {
        let entries: [String: Entry]? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            return items.mapValues(\.entry)
        }
        guard let entries, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func modified(_ path: String) -> Date? { lock.withLock { items[path]?.entry.modified } }
    func entry(_ path: String) -> Entry? { lock.withLock { items[path]?.entry } }

    func set(_ path: String, _ entry: Entry) {
        let indexed = Indexed(entry)
        lock.withLock { items[path] = indexed; dirty = true }
    }

    func prune(keeping paths: Set<String>) {
        lock.withLock {
            let gone = items.keys.filter { !paths.contains($0) }
            gone.forEach { items[$0] = nil }
            if !gone.isEmpty { dirty = true }
        }
    }

    /// Images matching a description, best first. Each word scores once: by a label Vision gave the
    /// picture (weighted by how sure it was) or by the text in it. With `strict`, every word must match.
    func search(_ query: [String], limit: Int, strict: Bool = false, textWeight: Double = 3.5) -> [Hit] {
        let words = query.flatMap { Self.words($0) }.filter { !Self.filler.contains($0) }.map(Self.stem)
        guard !words.isEmpty else { return [] }
        let wanted = words.map { Self.synonyms[$0] ?? [$0] }
        // Search plans add related words ("beach, coast, seaside"), so any one can match; each match adds up.
        let needed = strict ? words.count : 1

        let snapshot = lock.withLock { items }
        var hits: [Hit] = []
        for (path, item) in snapshot {
            var score = 0.0
            var matched = 0
            for (word, labels) in zip(words, wanted) {
                let label = labels.compactMap { item.labelWords[$0] }.max().map { Double($0) * 6 } ?? 0
                let text = item.textWords.contains(word) ? textWeight : 0
                let best = max(label, text)
                if best > 0 { score += best; matched += 1 }
            }
            guard matched >= needed, score > 0 else { continue }
            // Every word in the picture's own text ("CUBICLE Training Manual" on a photo of the manual)
            // is close to a caption, whatever the text weighs on its own.
            if words.count >= 2, words.allSatisfy({ item.textWords.contains($0) }) { score += 4 * Double(words.count) }
            hits.append(Hit(url: URL(fileURLWithPath: path), score: score, modified: item.entry.modified))
        }
        return Array(hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.modified > $1.modified }.prefix(limit))
    }

    /// Pictures that look like a description, according to MobileCLIP. Empty without the model.
    /// `relaxed` (the user asked for a picture): the best few count even when none stands out much.
    func visualSearch(_ description: String, limit: Int, strongOnly: Bool = false, relaxed: Bool = false) -> [VisualHit] {
        guard let clip = VisualSearch.model, !description.trimmingCharacters(in: .whitespaces).isEmpty,
              let query = try? clip.embed(text: description) else { return [] }
        let snapshot = lock.withLock { items }
        let scored = snapshot.compactMap { path, item in item.vector.map { (path, CLIPModel.similarity(query, $0)) } }
        // A standout needs a crowd to stand out from.
        guard scored.count >= 20 else { return [] }
        let mean = scored.reduce(0) { $0 + $1.1 } / Float(scored.count)
        let spread = (scored.reduce(0) { $0 + ($1.1 - mean) * ($1.1 - mean) } / Float(scored.count)).squareRoot()
        guard spread > 0 else { return [] }
        return scored.map { VisualHit(url: URL(fileURLWithPath: $0.0), similarity: $0.1, standout: ($0.1 - mean) / spread) }
            .filter { strongOnly ? $0.isStrong : $0.isPlausible || (relaxed && $0.standout >= 2) }
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .map { $0 }
    }

    /// Pictures in the same folder taken closest in time to this one: the rest of a burst of shots.
    func neighbors(of url: URL, limit: Int) -> [URL] {
        let folder = url.deletingLastPathComponent().path + "/"
        let snapshot = lock.withLock { items }
        guard let when = snapshot[url.path]?.entry.modified else { return [] }
        return snapshot.filter { path, item in
            path != url.path && path.hasPrefix(folder) && !path.dropFirst(folder.count).contains("/") && item.entry.readable
        }
        .sorted { abs($0.value.entry.modified.timeIntervalSince(when)) < abs($1.value.entry.modified.timeIntervalSince(when)) }
        .prefix(limit)
        .map { URL(fileURLWithPath: $0.key) }
    }

    /// Forgets every vector (MobileCLIP was removed).
    func removeVectors() {
        lock.withLock {
            for (path, item) in items where item.entry.vector != nil {
                var entry = item.entry
                entry.vector = nil
                entry.vectorScale = nil
                items[path] = Indexed(entry)
            }
            dirty = true
        }
        DispatchQueue.global(qos: .utility).async { self.save() }
    }

    /// A short description for the model that picks between files.
    func summary(_ path: String) -> [String] {
        guard let entry = entry(path) else { return [] }
        var lines: [String] = []
        let labels = entry.labels.sorted { $0.value > $1.value }.prefix(8).map { $0.key.replacingOccurrences(of: "_", with: " ") }
        if !labels.isEmpty { lines.append("image shows: \(labels.joined(separator: ", "))") }
        if !entry.text.isEmpty { lines.append("text in image: \(entry.text.prefix(160))") }
        return lines
    }

    // MARK: - Words

    fileprivate static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
    }

    /// Plurals down to their singular, so "dogs" finds "dog" and "puppies" finds "puppy".
    fileprivate static func stem(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 4, ["ches", "shes", "xes", "sses"].contains(where: word.hasSuffix) { return String(word.dropLast(2)) }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") { return String(word.dropLast()) }
        return word
    }

    /// Words that say a picture is wanted rather than what's in it.
    private static let filler: Set<String> = ["photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "img",
                                              "screenshot", "screenshots", "screen", "shot", "snap", "of", "on", "in", "at",
                                              "an", "the", "my", "me", "with", "and", "some", "that", "this", "from", "where",
                                              "find", "show", "took", "taken", "where", "one", "file"]

    /// Everyday words mapped onto Vision's label vocabulary.
    private static let synonyms: [String: [String]] = [
        "person": ["people", "adult"], "man": ["people", "adult"], "men": ["people", "adult"], "woman": ["people", "adult"],
        "women": ["people", "adult"], "guy": ["people", "adult"], "girl": ["people", "child", "teen"], "boy": ["people", "child", "teen"],
        "friend": ["people"], "family": ["people"], "selfie": ["people"], "face": ["people"], "group": ["people", "crowd"],
        "kid": ["child"], "children": ["child"], "puppy": ["dog", "canine"], "doggo": ["dog"], "kitty": ["cat", "kitten"],
        "sea": ["ocean", "water"], "lake": ["lake", "water"], "sunrise": ["sunset", "sunrise"], "dusk": ["sunset"],
        "meal": ["food"], "dinner": ["food", "restaurant"], "lunch": ["food"], "breakfast": ["food"], "dish": ["food"],
        "plane": ["airplane", "aircraft"], "bike": ["bicycle", "motorcycle"], "auto": ["car", "automobile"],
        "city": ["cityscape", "skyscraper", "street"], "night": ["night"], "stars": ["night", "celestial"],
        "party": ["celebration"], "christmas": ["christmas"], "invoice": ["receipt", "document"], "bill": ["receipt"],
        "graph": ["chart", "diagram"], "slide": ["document", "chart"], "notes": ["handwriting", "sticky", "document"],
        "handwritten": ["handwriting"], "page": ["document", "printed"], "flowers": ["flower"], "tree": ["tree"],
        "drink": ["drink", "beverage"], "coffee": ["coffee"], "snowy": ["snow"], "mountains": ["mountain"],
    ]
}
