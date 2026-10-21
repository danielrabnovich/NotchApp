import Foundation
import SQLite3

/// Recall's memory: one row per capture of a window (when, which app, its title, address and
/// text, what Vision saw, MobileCLIP's vector and a small picture), in a SQLite database with a
/// full-text index over the words. Application Support/NotchApp/Recall; nothing leaves the Mac.
final class RecallStore: @unchecked Sendable {
    static let shared = RecallStore()

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchApp/Recall", isDirectory: true)
    static let frames = folder.appendingPathComponent("Frames", isDirectory: true)
    /// The app decides this, not a setting: past it, the oldest captures go first.
    static let diskBudget: Int64 = 2_000_000_000

    struct Capture: Sendable {
        var time = Date()
        var bundleID: String?
        var appName: String?
        var title: String?
        /// The page's address, or the document's path.
        var location: String?
        var text = ""
        var labels: [String] = []
        var vector: [Float]?
        /// The picture's file name inside `frames`.
        var thumbnail: String?
        var bytes: Int64 = 0
    }

    struct Hit: Sendable, Identifiable {
        let id: Int64
        let time: Date
        let bundleID: String?
        let appName: String?
        let title: String?
        let location: String?
        let snippet: String
        /// FTS5's BM25 (lower is better; 0 when no words were searched).
        let bm25: Double
        let vector: [Float]?
        let thumbnail: URL?
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let file = folder.appendingPathComponent("recall.sqlite")

    /// Opens the database; `create` makes it when there's none yet (reading never does).
    /// False when there's nothing to open, or SQLite can't.
    @discardableResult
    func open(create: Bool = false) -> Bool {
        lock.withLock {
            if db != nil { return true }
            let fm = FileManager.default
            guard create || fm.fileExists(atPath: Self.file.path) else { return false }
            try? fm.createDirectory(at: Self.frames, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = Self.file.path
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                sqlite3_close(db); db = nil
                return false
            }
            sqlite3_busy_timeout(db, 500)
            exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS captures(
                id INTEGER PRIMARY KEY, time REAL NOT NULL, bundle TEXT, app TEXT, title TEXT, location TEXT,
                text TEXT, labels TEXT, vector BLOB, vscale REAL, thumb TEXT, bytes INTEGER DEFAULT 0);
            CREATE INDEX IF NOT EXISTS captures_time ON captures(time);
            CREATE VIRTUAL TABLE IF NOT EXISTS captures_fts USING fts5(
                title, location, text, labels, content='captures', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS captures_ai AFTER INSERT ON captures BEGIN
                INSERT INTO captures_fts(rowid, title, location, text, labels) VALUES (new.id, new.title, new.location, new.text, new.labels);
            END;
            CREATE TRIGGER IF NOT EXISTS captures_ad AFTER DELETE ON captures BEGIN
                INSERT INTO captures_fts(captures_fts, rowid, title, location, text, labels) VALUES ('delete', old.id, old.title, old.location, old.text, old.labels);
            END;
            """)
            return true
        }
    }

    /// Lets go of the database (Recall was turned off, or everything was forgotten).
    func close() {
        lock.withLock {
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - Writing

    func insert(_ c: Capture) {
        guard open(create: true) else { return }
        lock.withLock {
            let sql = "INSERT INTO captures(time, bundle, app, title, location, text, labels, vector, vscale, thumb, bytes) VALUES (?,?,?,?,?,?,?,?,?,?,?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, c.time.timeIntervalSince1970)
            bind(stmt, 2, c.bundleID)
            bind(stmt, 3, c.appName)
            bind(stmt, 4, c.title)
            bind(stmt, 5, c.location)
            bind(stmt, 6, c.text)
            bind(stmt, 7, c.labels.isEmpty ? nil : c.labels.joined(separator: " "))
            if let (data, scale) = c.vector.map(Self.quantize) {
                _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 8, $0.baseAddress, Int32(data.count), Self.SQLITE_TRANSIENT) }
                sqlite3_bind_double(stmt, 9, Double(scale))
            }
            bind(stmt, 10, c.thumbnail)
            sqlite3_bind_int64(stmt, 11, c.bytes)
            sqlite3_step(stmt)
        }
    }

    /// Captures still without a vector (MobileCLIP wasn't loaded when they were taken), newest first.
    func needingVectors(limit: Int) -> [(id: Int64, thumbnail: URL)] {
        guard open() else { return [] }
        return lock.withLock {
            rows("SELECT id, thumb FROM captures WHERE vector IS NULL AND thumb IS NOT NULL ORDER BY time DESC LIMIT \(limit)") { stmt in
                (sqlite3_column_int64(stmt, 0), Self.frames.appendingPathComponent(Self.text(stmt, 1) ?? ""))
            }
        }
    }

    func setVector(_ id: Int64, _ vector: [Float]) {
        guard open() else { return }
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE captures SET vector = ?, vscale = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let (data, scale) = Self.quantize(vector)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), Self.SQLITE_TRANSIENT) }
            sqlite3_bind_double(stmt, 2, Double(scale))
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
    }

    /// Forgets captures taken since `date` (the last hour), pictures included.
    func forget(since date: Date) {
        delete(where: "time >= \(date.timeIntervalSince1970)")
    }

    /// Forgets everything: the database and every picture.
    func forgetAll() {
        close()
        try? FileManager.default.removeItem(at: Self.folder)
    }

    /// Drops what's older than `keep`, then the oldest until it all fits the disk budget.
    func prune(keep: TimeInterval) {
        guard open() else { return }
        delete(where: "time < \(Date().addingTimeInterval(-keep).timeIntervalSince1970)")
        var total = usedBytes()
        while total > Self.diskBudget {
            let count = lock.withLock { rows("SELECT COUNT(*) FROM captures") { sqlite3_column_int64($0, 0) }.first ?? 0 }
            guard count > 0 else { break }
            let cutoff = lock.withLock {
                rows("SELECT time FROM captures ORDER BY time LIMIT 1 OFFSET \(max(count / 10, 1))") { sqlite3_column_double($0, 0) }.first
            }
            guard let cutoff else { break }
            delete(where: "time < \(cutoff)")
            total = usedBytes()
        }
        lock.withLock { exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA optimize;") }
    }

    private func delete(where condition: String) {
        guard open() else { return }
        let thumbs = lock.withLock { rows("SELECT thumb FROM captures WHERE \(condition) AND thumb IS NOT NULL") { Self.text($0, 0) } }
        lock.withLock { exec("DELETE FROM captures WHERE \(condition)") }
        for name in thumbs.compactMap({ $0 }) { try? FileManager.default.removeItem(at: Self.frames.appendingPathComponent(name)) }
    }

    // MARK: - Reading

    /// Pictures plus text, and the database file itself.
    func usedBytes() -> Int64 {
        guard open() else { return 0 }
        let rowsBytes = lock.withLock { rows("SELECT COALESCE(SUM(bytes), 0) FROM captures") { sqlite3_column_int64($0, 0) }.first ?? 0 }
        let fm = FileManager.default
        let files = ["recall.sqlite", "recall.sqlite-wal"].reduce(Int64(0)) { sum, name in
            sum + ((try? fm.attributesOfItem(atPath: Self.folder.appendingPathComponent(name).path)[.size] as? Int64) ?? 0)
        }
        return rowsBytes + files
    }

    var count: Int {
        guard open() else { return 0 }
        return lock.withLock { Int(rows("SELECT COUNT(*) FROM captures") { sqlite3_column_int64($0, 0) }.first ?? 0) }
    }

    /// Every app seen, by name, with its bundle ID (to match "in Slack").
    func apps() -> [(name: String, bundleID: String)] {
        guard open() else { return [] }
        return lock.withLock {
            rows("SELECT app, bundle FROM captures WHERE app IS NOT NULL GROUP BY bundle") { (Self.text($0, 0) ?? "", Self.text($0, 1) ?? "") }
        }
    }

    /// Captures in the time range and apps, matching any of `words` (best first by BM25), or the
    /// newest when there are no words.
    func search(words: [String], from: Date?, to: Date?, bundleIDs: [String], limit: Int) -> [Hit] {
        guard open() else { return [] }
        var conditions: [String] = []
        if let from { conditions.append("c.time >= \(from.timeIntervalSince1970)") }
        if let to { conditions.append("c.time < \(to.timeIntervalSince1970)") }
        if !bundleIDs.isEmpty { conditions.append("c.bundle IN (\(bundleIDs.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")))") }
        let columns = "c.id, c.time, c.bundle, c.app, c.title, c.location, c.vector, c.vscale, c.thumb"
        let match = Self.matchExpression(words)
        let sql: String
        if match != nil {
            let filter = conditions.isEmpty ? "" : " AND " + conditions.joined(separator: " AND ")
            // Title and address weigh most: they say what the window was.
            sql = """
            SELECT \(columns), snippet(captures_fts, 2, '', '', '…', 18), bm25(captures_fts, 6.0, 4.0, 1.0, 1.5) AS rank
            FROM captures_fts JOIN captures c ON c.id = captures_fts.rowid
            WHERE captures_fts MATCH ?\(filter) ORDER BY rank LIMIT \(limit)
            """
        } else {
            let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
            sql = "SELECT \(columns), substr(c.text, 1, 160), 0 FROM captures c\(filter) ORDER BY c.time DESC LIMIT \(limit)"
        }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                DebugHooks.log("Recall search failed: \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            defer { sqlite3_finalize(stmt) }
            if let match { sqlite3_bind_text(stmt, 1, match, -1, Self.SQLITE_TRANSIENT) }
            var hits: [Hit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var vector: [Float]?
                if let blob = sqlite3_column_blob(stmt, 6) {
                    let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 6)))
                    vector = Self.floats(data, scale: Float(sqlite3_column_double(stmt, 7)))
                }
                hits.append(Hit(id: sqlite3_column_int64(stmt, 0),
                                time: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                                bundleID: Self.text(stmt, 2), appName: Self.text(stmt, 3), title: Self.text(stmt, 4),
                                location: Self.text(stmt, 5),
                                snippet: (Self.text(stmt, 9) ?? "").split(whereSeparator: \.isNewline).joined(separator: " "),
                                bm25: sqlite3_column_double(stmt, 10), vector: vector,
                                thumbnail: Self.text(stmt, 8).map { Self.frames.appendingPathComponent($0) }))
            }
            return hits
        }
    }

    /// The text of one capture, for the model to answer from.
    func text(of id: Int64) -> String {
        guard open() else { return "" }
        return lock.withLock { rows("SELECT text FROM captures WHERE id = \(id)") { Self.text($0, 0) ?? "" }.first ?? "" }
    }

    /// FTS5 query: each word as a prefix, any of them (BM25 ranks captures with more of them higher).
    static func matchExpression(_ words: [String]) -> String? {
        let terms = words.map { $0.filter { $0.isLetter || $0.isNumber } }.filter { $0.count >= 2 }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    // MARK: - SQLite

    /// Called with the lock held.
    private func exec(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK, let error {
            DebugHooks.log("Recall SQL: \(String(cString: error))")
            sqlite3_free(error)
        }
    }

    /// Called with the lock held.
    private func rows<T>(_ sql: String, _ read: (OpaquePointer?) -> T) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(read(stmt)) }
        return out
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, index) }
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    /// 512 values as bytes with their scale, as the picture index keeps them.
    private static func quantize(_ values: [Float]) -> (Data, Float) {
        let scale = max(values.map(abs).max() ?? 0, .leastNormalMagnitude) / 127
        return (Data(values.map { UInt8(bitPattern: Int8(($0 / scale).rounded())) }), scale)
    }

    private static func floats(_ data: Data, scale: Float) -> [Float]? {
        let values = data.map { Float(Int8(bitPattern: $0)) * scale }
        let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? values.map { $0 / norm } : nil
    }
}
