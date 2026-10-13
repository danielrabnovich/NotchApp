import AppKit

/// Quick fixes for copied text: plain text, pretty JSON, Base64, URL encoding, case, tidying.
enum TextTransform: String, CaseIterable, Identifiable {
    case plain, prettyJSON, minifyJSON, base64Encode, base64Decode, urlEncode, urlDecode,
         uppercase, lowercase, titleCase, trim, oneLine, sortLines, uniqueLines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: "Paste as Plain Text"
        case .prettyJSON: "Format JSON"
        case .minifyJSON: "Minify JSON"
        case .base64Encode: "Base64 Encode"
        case .base64Decode: "Base64 Decode"
        case .urlEncode: "URL Encode"
        case .urlDecode: "URL Decode"
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .titleCase: "Title Case"
        case .trim: "Trim Whitespace"
        case .oneLine: "Join Lines"
        case .sortLines: "Sort Lines"
        case .uniqueLines: "Remove Duplicate Lines"
        }
    }

    /// Its symbol in menus.
    var symbol: String {
        switch self {
        case .plain: "textformat"
        case .prettyJSON: "curlybraces"
        case .minifyJSON: "arrow.down.right.and.arrow.up.left"
        case .base64Encode: "lock"
        case .base64Decode: "lock.open"
        case .urlEncode: "link.badge.plus"
        case .urlDecode: "link"
        case .uppercase: "textformat.size.larger"
        case .lowercase: "textformat.size.smaller"
        case .titleCase: "textformat.alt"
        case .trim: "scissors"
        case .oneLine: "arrow.right.to.line"
        case .sortLines: "arrow.up.arrow.down"
        case .uniqueLines: "line.3.horizontal.decrease"
        }
    }

    /// Words typed in Search that pick this transform.
    var phrases: [String] {
        switch self {
        case .plain: ["plain text", "paste plain", "strip formatting", "remove formatting"]
        case .prettyJSON: ["format json", "pretty json", "prettify json"]
        case .minifyJSON: ["minify json", "compact json"]
        case .base64Encode: ["base64", "base64 encode", "encode base64"]
        case .base64Decode: ["base64 decode", "decode base64", "unbase64"]
        case .urlEncode: ["url encode", "urlencode", "encode url", "percent encode"]
        case .urlDecode: ["url decode", "urldecode", "decode url"]
        case .uppercase: ["uppercase", "upper case"]
        case .lowercase: ["lowercase", "lower case"]
        case .titleCase: ["title case", "titlecase", "capitalize"]
        case .trim: ["trim whitespace"]
        case .oneLine: ["join lines", "one line", "remove line breaks"]
        case .sortLines: ["sort lines"]
        case .uniqueLines: ["unique lines", "dedupe lines", "remove duplicates"]
        }
    }

    /// The transformed text, or nil if it doesn't apply (not JSON, not Base64…).
    func apply(_ text: String) -> String? {
        switch self {
        case .plain: return text
        case .prettyJSON, .minifyJSON:
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
            let options: JSONSerialization.WritingOptions = self == .prettyJSON ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                                                                : [.withoutEscapingSlashes]
            // Parsing allows fragments ("42", "\"hi\""), but writing one throws an Objective-C
            // exception that `try?` can't catch, and crashed the app whenever a clip card checked
            // its transforms. Only containers are formatted.
            guard obj is [Any] || obj is [String: Any], JSONSerialization.isValidJSONObject(obj) else { return nil }
            return (try? JSONSerialization.data(withJSONObject: obj, options: options)).flatMap { String(data: $0, encoding: .utf8) }
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while s.count % 4 != 0 { s += "=" }
            return Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) }
        case .urlEncode: return text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?/:#")))
        case .urlDecode: return text.removingPercentEncoding
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return text.capitalized
        case .trim:
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .oneLine:
            return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        case .sortLines:
            return text.split(separator: "\n").map(String.init).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
        case .uniqueLines:
            var seen = Set<String>()
            return text.split(separator: "\n").map(String.init).filter { seen.insert($0).inserted }.joined(separator: "\n")
        }
    }

    /// Transforms that make sense for this text (JSON options only for JSON, and so on).
    static func applicable(to text: String) -> [TextTransform] {
        allCases.filter { t in
            guard let out = t.apply(text) else { return false }
            return t == .plain || out != text
        }
    }

    /// Transforms the clipboard's text in place and says what happened.
    @MainActor static func applyToClipboard(_ t: TextTransform) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            ActivityCenter.shared.show(.notice(title: "No text on the clipboard", detail: t.title, icon: "doc.on.clipboard", tone: .warning), for: 2.5)
            return
        }
        guard let out = t.apply(text) else {
            ActivityCenter.shared.show(.notice(title: "Couldn't \(t.title.lowercased())", detail: "The clipboard isn't valid for that", icon: "xmark.circle", tone: .warning), for: 3)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
        ActivityCenter.shared.show(.notice(title: t.title, detail: String(out.replacingOccurrences(of: "\n", with: " ").prefix(48)),
                                           icon: "wand.and.rays"), for: 2.5)
    }
}

extension NSPasteboard {
    /// A few words about what's on the clipboard, for previews.
    var shortText: String? {
        string(forType: .string).map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(40)) }
    }
}
