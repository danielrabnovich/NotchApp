import Foundation

struct WebSource: Identifiable, Equatable, Sendable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
    let snippet: String
    var host: String { url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString }
}

/// Answers a question from the web: DuckDuckGo search → read the top pages → summarize locally.
/// Only the search query and page fetches leave the Mac; the model runs on-device.
enum WebSearcher {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": "en-US,en;q=0.9"]
        return URLSession(configuration: config)
    }()

    /// One search at a time: search engines throttle bursts of requests.
    private actor Gate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func enter() async {
            if !busy { busy = true; return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func leave() {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
    }
    private static let gate = Gate()

    static func answer(_ question: String, searchQuery: String,
                       progress: @escaping @Sendable (String) async -> Void,
                       partial: @escaping @Sendable (String, [WebSource]) async -> Void) async throws -> (answer: String, sources: [WebSource]) {
        await progress("Searching the web")
        await gate.enter()
        // Brave first (best results), then DuckDuckGo, then Bing – whichever answers.
        var results = (try? await searchBrave(searchQuery)) ?? []
        if results.isEmpty { results = (try? await searchDuckDuckGo(searchQuery)) ?? [] }
        if results.isEmpty { results = (try? await searchBing(searchQuery)) ?? [] }
        await gate.leave()
        DebugHooks.log("Web search '\(searchQuery)': \(results.count) results")
        guard !results.isEmpty else {
            throw OllamaClient.OllamaError(message: "Couldn't reach a search engine. Check your connection and try again.")
        }

        await progress("Reading \(min(3, results.count)) pages")
        let pages = await withTaskGroup(of: (Int, String).self) { group in
            for (i, r) in results.prefix(3).enumerated() {
                group.addTask { (i, (try? await pageText(r.url)) ?? "") }
            }
            var out = [Int: String]()
            for await (i, text) in group { out[i] = text }
            return out
        }

        await progress("Writing an answer")
        var context = ""
        for (i, r) in results.prefix(6).enumerated() {
            context += "[\(i + 1)] \(r.title)\nURL: \(r.url.absoluteString)\nSnippet: \(r.snippet)\n"
            if let text = pages[i], !text.isEmpty { context += "Page text: \(text.prefix(2500))\n" }
            context += "\n"
        }
        let system = """
        You are a concise research assistant. Answer the user's question using ONLY the numbered web sources. \
        Today is \(Date().formatted(date: .complete, time: .omitted)). \
        Start with a one-sentence direct answer. Then, only if useful, add up to 4 short "• " bullet lines with key details. \
        Plain text only: no markdown, no headings, no bold. Under 110 words. Cite sources inline like [1] or [2][3]. \
        When sources disagree or the question is about the latest/most recent thing, trust the newest information \
        relative to today's date. If the sources don't answer the question, say so briefly.
        """
        let sources = Array(results.prefix(6))
        let text = try await OllamaClient.chatStream(system: system, user: "Question: \(question)\n\nSources:\n\(context)") { soFar in
            await partial(soFar, sources)
        }
        return (text, sources)
    }

    // MARK: - Search

    private static func searchDuckDuckGo(_ query: String) async throws -> [WebSource] {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, _) = try await session.data(from: comps.url!)
        let html = String(decoding: data, as: UTF8.self)

        // Each organic result: <a ... class="result__a" href="URL">Title</a> … <a class="result__snippet" …>Snippet</a>
        var results: [WebSource] = []
        let blocks = html.components(separatedBy: "class=\"result__a\"").dropFirst()
        for block in blocks {
            guard let href = firstMatch(#"href="([^"]+)""#, in: block),
                  let titleHTML = firstMatch(#">(.*?)</a>"#, in: block),
                  let url = resolve(decodeEntities(href)) else { continue }
            if url.host?.contains("duckduckgo.com") == true { continue } // ads
            let snippet = firstMatch(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: block) ?? ""
            results.append(WebSource(title: clean(titleHTML), url: url, snippet: clean(snippet)))
            if results.count == 8 { break }
        }
        return results
    }

    private static func searchBrave(_ query: String) async throws -> [WebSource] {
        var comps = URLComponents(string: "https://search.brave.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "source", value: "web")]
        let (data, _) = try await session.data(from: comps.url!)
        let html = String(decoding: data, as: UTF8.self)
        var results: [WebSource] = []
        for block in html.components(separatedBy: "data-type=\"web\"").dropFirst() {
            guard let href = firstMatch(#"<a href="(https?://[^"]+)""#, in: block),
                  let title = firstMatch(#"search-snippet-title[^"]*" title="([^"]+)""#, in: block),
                  let url = URL(string: decodeEntities(href)),
                  url.host?.contains("brave.com") != true else { continue }
            let snippet = firstMatch(#"class="content[^"]*">(.*?)</div>"#, in: block) ?? ""
            results.append(WebSource(title: decodeEntities(title), url: url, snippet: clean(snippet)))
            if results.count == 8 { break }
        }
        return results
    }

    /// Fallback when DuckDuckGo is throttling. Bing wraps result links in `/ck/a?…&u=a1<base64url>`.
    private static func searchBing(_ query: String) async throws -> [WebSource] {
        var comps = URLComponents(string: "https://www.bing.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "setlang", value: "en")]
        let (data, _) = try await session.data(from: comps.url!)
        let html = String(decoding: data, as: UTF8.self)
        var results: [WebSource] = []
        for block in html.components(separatedBy: "<li class=\"b_algo\"").dropFirst() {
            guard let href = firstMatch(#"<h2[^>]*><a[^>]*href="([^"]+)""#, in: block),
                  let titleHTML = firstMatch(#"<h2[^>]*><a[^>]*>(.*?)</a>"#, in: block) else { continue }
            var link = decodeEntities(href)
            if let u = URLComponents(string: link)?.queryItems?.first(where: { $0.name == "u" })?.value, u.hasPrefix("a1") {
                var b64 = String(u.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while b64.count % 4 != 0 { b64 += "=" }
                if let d = Data(base64Encoded: b64), let s = String(data: d, encoding: .utf8) { link = s }
            }
            guard let url = URL(string: link), url.scheme?.hasPrefix("http") == true else { continue }
            let snippet = firstMatch(#"<p[^>]*>(.*?)</p>"#, in: block) ?? ""
            results.append(WebSource(title: clean(titleHTML), url: url, snippet: clean(snippet)))
            if results.count == 8 { break }
        }
        return results
    }

    /// DuckDuckGo sometimes wraps links in a redirect (`/l/?uddg=<encoded>`).
    private static func resolve(_ href: String) -> URL? {
        let full = href.hasPrefix("//") ? "https:" + href : href
        guard let url = URL(string: full) else { return nil }
        if url.path == "/l/", let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "uddg" })?.value {
            return URL(string: target)
        }
        return url.scheme?.hasPrefix("http") == true ? url : nil
    }

    // MARK: - Page text

    private static func pageText(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "text/html").contains("html") else { return "" }
        var html = String(decoding: data.prefix(600_000), as: UTF8.self)
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "form"] {
            html = html.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return clean(html)
    }

    private static func clean(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(noTags).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#x2F;": "/", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
