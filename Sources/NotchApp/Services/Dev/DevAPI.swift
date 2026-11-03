import Foundation

/// JSON over HTTPS for the developer services (Vercel, Linear). GitHub has its own, for its headers
/// and polling rules.
enum DevAPI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "NotchApp", "Accept": "application/json"]
        return URLSession(configuration: c)
    }()

    /// The parsed answer, and the status code.
    static func json(_ url: URL, method: String = "GET", headers: [String: String], body: Any? = nil) async throws -> (Any?, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data), code)
    }

    static func date(_ any: Any?) -> Date? {
        if let ms = any as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = any as? Int { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        if let s = any as? String { return try? Date(s, strategy: .iso8601) }
        return nil
    }
}
