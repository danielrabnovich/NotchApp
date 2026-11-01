import SwiftUI

/// Answer text with citation markers like [2] drawn as small accent badges.
struct AnswerText: View {
    let text: String
    let accent: Color
    /// "Settings → Shelf → Quick drops" becomes a link to that page (help answers).
    var settingsLinks = false
    /// Every paragraph the same size (a chat reply), rather than the first one leading.
    var uniform = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .code(code, language):
                    CodeBlock(code: code, language: language)
                case let .prose(paras, first):
                    // One Text for every paragraph and bullet between code blocks: a selection
                    // can't cross from one Text into the next, so separate ones let you copy one
                    // bullet at a time.
                    prose(paras, startingAt: first)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private enum Block {
        case prose([(text: String, isBullet: Bool)], first: Int)
        case code(String, language: String?)
    }

    /// Runs of paragraphs and bullets, split by code blocks. `first` is the run's first paragraph's
    /// place in the whole answer (the very first one leads, bigger).
    private var blocks: [Block] {
        var out: [Block] = []
        var run: [(text: String, isBullet: Bool)] = []
        var runStart = 0
        for (i, para) in paragraphs.enumerated() {
            if para.isCode {
                if !run.isEmpty { out.append(.prose(run, first: runStart)); run = [] }
                out.append(.code(para.text, language: para.language))
            } else {
                if run.isEmpty { runStart = i }
                run.append((para.text, para.isBullet))
            }
        }
        if !run.isEmpty { out.append(.prose(run, first: runStart)) }
        return out
    }

    private func prose(_ paras: [(text: String, isBullet: Bool)], startingAt first: Int) -> Text {
        var result = Text("")
        for (k, para) in paras.enumerated() {
            let i = first + k
            let leads = !uniform && i == 0 && !para.isBullet
            if k > 0 {
                // A short blank line between paragraphs, as the old stack's spacing was.
                result = result + Text("\n") + Text("\n").font(.system(size: 4))
            }
            let font: Font = uniform ? .system(size: 13) : .system(size: leads ? 14.5 : 12.5, weight: leads ? .medium : .regular)
            let color = Color.white.opacity(uniform ? 0.9 : i == 0 ? 0.95 : 0.78)
            if para.isBullet { result = result + Text("•  ").font(font).foregroundColor(.white.opacity(0.5)) }
            result = result + styled(para.text).font(font).foregroundColor(color)
        }
        return result
    }

    /// Lines as paragraphs and bullets, and ``` fenced code as blocks (kept verbatim, indentation
    /// and all; a fence still open while the answer streams in is already a block).
    private var paragraphs: [(text: String, isBullet: Bool, isCode: Bool, language: String?)] {
        var out: [(String, Bool, Bool, String?)] = []
        var code: [String]?
        var language: String?
        // Models sometimes put "•" bullets inline; give each its own line.
        for raw in text.replacingOccurrences(of: " • ", with: "\n• ").components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    if !lines.isEmpty { out.append((lines.joined(separator: "\n"), false, true, language)) }
                    code = nil
                } else {
                    code = []
                    // "```python" names the language.
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            guard !trimmed.isEmpty else { continue }
            if let prefix = ["• ", "- ", "* "].first(where: trimmed.hasPrefix) {
                out.append((String(trimmed.dropFirst(prefix.count)), true, false, nil))
            } else if trimmed.hasPrefix("#") {
                // A heading reads as a bold line.
                out.append(("**" + trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**", false, false, nil))
            } else {
                out.append((trimmed, false, false, nil))
            }
        }
        if let lines = code, !lines.isEmpty { out.append((lines.joined(separator: "\n"), false, true, language)) }
        return out
    }

    /// Citations ([1]) as small superscripts, `inline code` in monospace, and **bold** as bold.
    private func styled(_ s: String) -> Text {
        var result = Text("")
        for (i, part) in s.components(separatedBy: "`").enumerated() {
            if i % 2 == 1, !part.isEmpty {
                result = result + Text(part).font(.system(size: 12, design: .monospaced)).foregroundColor(.white.opacity(0.92))
            } else {
                for (j, run) in part.components(separatedBy: "**").enumerated() {
                    result = result + (j % 2 == 1 ? cited(run).bold().foregroundColor(.white.opacity(0.95)) : cited(run))
                }
            }
        }
        return result
    }

    private func cited(_ s: String) -> Text {
        var result = Text("")
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]"),
              Int(rest[rest.index(after: open)..<close]) != nil {
            result = result + linked(String(rest[..<open]))
            let n = String(rest[rest.index(after: open)..<close])
            result = result + Text(" \(n)").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.45)).baselineOffset(4)
            rest = rest[rest.index(after: close)...]
        }
        return result + linked(String(rest))
    }

    private func linked(_ s: String) -> Text {
        guard settingsLinks, s.contains("Settings") else { return Text(s) }
        var result = Text("")
        for part in HelpBrain.linkify(s) {
            if let url = part.link {
                var a = AttributedString(part.text)
                a.link = url
                a.foregroundColor = accent
                a.underlineStyle = .single
                result = result + Text(a)
            } else {
                result = result + Text(part.text)
            }
        }
        return result
    }
}

/// Code from an answer: syntax-coloured and monospaced on a soft panel, with a copy button.
private struct CodeBlock: View {
    let code: String
    var language: String?
    @State private var copied = false

    var body: some View {
        Text(SyntaxHighlighter.highlight(code, language: language))
            .font(.system(size: 11.5, design: .monospaced))
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .padding(.trailing, 18)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    ClipboardHistory.shared.ignoreCurrent()
                    copied = true
                    Haptics.tap()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(NotchIconButtonStyle(size: 20))
                .padding(3)
                .help("Copy code")
            }
    }
}
