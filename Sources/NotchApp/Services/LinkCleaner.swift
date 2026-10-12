import Foundation

/// Takes the tracking off a copied link: campaign tags (utm_…), click IDs (fbclid, gclid…), share
/// IDs (YouTube's and Spotify's si) and shop referral clutter, and turns a redirect (Google's
/// /url?q=, Facebook's l.php?u=) into where it leads. Everything else in the link stays as it
/// was, in its order; a link with nothing to take off is left alone.
enum LinkCleaner {
    struct Result: Equatable {
        let link: String
        /// How many tracking parts came off (a redirect unwrapped counts as one).
        let removed: Int
    }

    /// Exact names, any site.
    private static let names: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id",
        "mc_cid", "mc_eid", "igshid", "igsh", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "mkt_tok", "vero_id", "vero_conv", "oly_anon_id", "oly_enc_id", "rb_clickid", "wickedid", "s_cid", "ref_src",
        "ref_url", "sc_cid", "srsltid", "trk", "trkcampaign", "_ga", "_gl", "epik", "spm", "scm",
    ]
    /// Any name starting with these.
    private static let prefixes = ["utm_", "pk_", "mtm_", "pd_rd_", "pf_rd_", "_bta_"]
    /// Only on these sites, where the same name means tracking (elsewhere it may not).
    private static let perSite: [String: Set<String>] = [
        "youtube.com": ["si", "pp", "feature"], "youtu.be": ["si", "feature"], "music.youtube.com": ["si"],
        "open.spotify.com": ["si", "context", "nd"], "x.com": ["s", "t"], "twitter.com": ["s", "t"],
        "instagram.com": ["igsh", "img_index"], "threads.net": ["xmt", "slof"], "threads.com": ["xmt", "slof"],
        "tiktok.com": ["_r", "_t", "is_from_webapp", "sender_device", "web_id"],
        "amazon.com": ["ref", "ref_", "psc", "smid", "content-id", "_encoding", "linkcode", "linkid", "camp", "creative", "crid", "sprefix", "qid", "dib", "dib_tag"],
        "linkedin.com": ["trackingid", "refid", "lipi", "midtoken", "midsig", "trk", "trkemail", "eid", "otptoken"],
        "reddit.com": ["share_id", "rdt"], "medium.com": ["source", "sk"],
    ]
    /// Redirect pages and the parameter holding where they lead.
    private static let redirects: [(host: String, path: String, key: String)] = [
        ("google.com", "/url", "q"), ("google.com", "/url", "url"), ("l.facebook.com", "/l.php", "u"),
        ("lm.facebook.com", "/l.php", "u"), ("l.instagram.com", "/", "u"), ("out.reddit.com", "", "url"),
        ("t.umblr.com", "/redirect", "z"), ("away.vk.com", "/away.php", "to"), ("slack-redir.net", "/link", "url"),
    ]

    /// The link without its tracking, or nil when there's nothing to take off (or it isn't a link).
    static func clean(_ raw: String) -> Result? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace), var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = parts.host?.lowercased() else { return nil }
        var removed = 0

        // A redirect: where it leads, cleaned in turn.
        if let hop = redirects.first(where: { matches(host, $0.host) && (parts.path == $0.path || $0.path.isEmpty) }),
           let target = parts.queryItems?.first(where: { $0.name == hop.key })?.value,
           let url = URL(string: target), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let inner = clean(target)
            return Result(link: inner?.link ?? target, removed: 1 + (inner?.removed ?? 0))
        }

        if let items = parts.queryItems, !items.isEmpty {
            // Amazon's every country (amazon.co.uk, amazon.de…) takes the same.
            let site = (host.contains("amazon.") ? perSite["amazon.com"] : perSite.first { matches(host, $0.key) }?.value) ?? []
            let kept = items.filter { item in
                let name = item.name.lowercased()
                let tracking = names.contains(name) || prefixes.contains(where: name.hasPrefix) || site.contains(name)
                if tracking { removed += 1 }
                return !tracking
            }
            if removed > 0 {
                // Rebuilt from the original text so the parameters that stay keep their exact encoding.
                parts.percentEncodedQuery = kept.isEmpty ? nil : keptQuery(parts.percentEncodedQuery ?? "", keeping: Set(kept.map(\.name)))
            }
        }
        // Amazon's /ref=… path segment.
        if matches(host, "amazon.com") || host.hasPrefix("amazon.") || host.contains(".amazon."),
           let range = parts.path.range(of: #"/ref=[^/]*$"#, options: .regularExpression) {
            parts.path.removeSubrange(range)
            removed += 1
        }
        guard removed > 0, let link = parts.string else { return nil }
        return Result(link: link, removed: removed)
    }

    /// `host` is `domain` or one of its subdomains (www.youtube.com is youtube.com).
    private static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private static func keptQuery(_ query: String, keeping names: Set<String>) -> String? {
        let pieces = query.split(separator: "&", omittingEmptySubsequences: true).filter { piece in
            let name = piece.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            return names.contains(name.removingPercentEncoding ?? name)
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "&")
    }
}
