import AppKit
import SwiftUI

/// A site's icon, fetched from the site itself (its /favicon.ico, the same host the answer was read
/// from, so nothing new learns what was searched) and kept for the session.
@MainActor
enum Favicons {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    private static var loading: [String: Task<NSImage?, Never>] = [:]
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        return URLSession(configuration: config)
    }()

    static func cached(_ host: String) -> NSImage? { cache[host] }

    static func load(_ host: String) async -> NSImage? {
        if let image = cache[host] { return image }
        if missing.contains(host) { return nil }
        if let task = loading[host] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let url = URL(string: "https://\(host)/favicon.ico"),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data), image.isValid, image.size.width >= 8 else { return nil }
            return image
        }
        loading[host] = task
        let image = await task.value
        loading[host] = nil
        if let image { cache[host] = image } else { missing.insert(host) }
        return image
    }
}

/// The site's icon, or `fallback` until it arrives (or if there isn't one).
struct Favicon<Fallback: View>: View {
    let host: String
    var size: CGFloat = 16
    @ViewBuilder let fallback: () -> Fallback
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? Favicons.cached(host) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                fallback()
            }
        }
        .task(id: host) { image = await Favicons.load(host) }
    }
}
