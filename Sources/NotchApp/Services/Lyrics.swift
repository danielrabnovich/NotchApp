import Foundation
import NotchKit

/// Time-synced lyrics for whatever's playing, from LRCLIB (lrclib.net: free, open, no key).
/// Nothing is fetched until lyrics are turned on from the music card; then only the song's title,
/// artist, album and length are sent, once per song.
@MainActor
final class Lyrics: ObservableObject {
    static let shared = Lyrics()

    typealias Line = LRC.Line

    enum State: Equatable {
        case off, loading, synced([Line]), none
    }

    /// Lyrics on the music card (remembered); the toggle is the card's own button.
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "lyricsEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "lyricsEnabled")
            refresh()
        }
    }
    @Published private(set) var state: State = .off

    private var key = ""
    private var cache: [String: [Line]?] = [:]
    private var task: Task<Void, Never>?

    /// Called when the track changes (and when lyrics are switched on).
    func refresh() {
        let media = MediaController.shared
        guard enabled, media.hasTrack else { task?.cancel(); state = .off; key = ""; return }
        let key = [media.title, media.artist].joined(separator: "\u{1F}").lowercased()
        guard key != self.key || state == .off else { return }
        self.key = key
        task?.cancel()
        if let hit = cache[key] { state = hit.map { .synced($0) } ?? .none; return }
        state = .loading
        let (title, artist, album, duration) = (media.title, media.artist, media.album, media.duration)
        task = Task { [weak self] in
            let lines = await Self.fetch(title: title, artist: artist, album: album, duration: duration)
            guard !Task.isCancelled, let self, self.key == key else { return }
            if self.cache.count > 200 { self.cache.removeAll() }
            self.cache[key] = lines
            self.state = lines.map { .synced($0) } ?? .none
        }
    }

    static func position(in lines: [Line], at time: Double) -> (index: Int, progress: Double)? {
        LRC.position(in: lines, at: time)
    }

    // MARK: - LRCLIB

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        // LRCLIB asks apps to say who they are.
        c.httpAdditionalHeaders = ["User-Agent": "NotchApp (https://github.com/danielrabnovich/NotchApp)"]
        return URLSession(configuration: c)
    }()

    private struct Record: Decodable {
        let syncedLyrics: String?
        let duration: Double?
        let instrumental: Bool?
    }

    /// The exact match first (title, artist, album and length), then a search, picking the result
    /// nearest the song's length that has synced lines.
    nonisolated private static func fetch(title: String, artist: String, album: String, duration: Double) async -> [Line]? {
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
            + (album.isEmpty ? [] : [.init(name: "album_name", value: album)])
            + (duration > 0 ? [.init(name: "duration", value: String(Int(duration.rounded())))] : [])
        if let url = get.url, let (data, response) = try? await session.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let record = try? JSONDecoder().decode(Record.self, from: data),
           let lines = record.syncedLyrics.map(parse), !lines.isEmpty {
            return lines
        }
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
        guard let url = search.url, let (data, _) = try? await session.data(from: url),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return nil }
        let best = records
            .filter { $0.syncedLyrics?.isEmpty == false }
            .filter { duration <= 0 || abs(($0.duration ?? duration) - duration) < 6 }
            .min { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }
        return best?.syncedLyrics.map(parse).flatMap { $0.isEmpty ? nil : $0 }
    }

    nonisolated static func parse(_ lrc: String) -> [Line] { LRC.parse(lrc) }
}
