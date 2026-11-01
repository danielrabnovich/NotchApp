import AppKit
import CoreText
import NotchKit

/// The emoji picker in Search: what's typed after ":" finds emoji and characters, ↩ types the
/// highlighted one into the app you were in. Keeps the skin tone you chose and the ones you use.
@MainActor
final class EmojiPicker: ObservableObject {
    static let shared = EmojiPicker()

    /// A run of emoji under a heading: "Frequently Used", a group, or the results.
    struct Section: Identifiable {
        let id: String
        let title: String?
        let emoji: [Emoji]
    }

    @Published private(set) var catalog: EmojiCatalog?
    @Published private(set) var sections: [Section] = []
    /// Bumped whenever the list is rebuilt: the grid starts afresh (a lazy grid going from every
    /// group to a few results kept showing cells from before).
    @Published private(set) var generation = 0
    /// Which emoji is highlighted, counting through every section.
    @Published var selected = 0
    /// 0 none (the yellow ones), 1–5 light to dark.
    @Published var tone: Int {
        didSet { UserDefaults.standard.set(tone, forKey: Self.toneKey) }
    }
    /// Cells per row, set by the grid as it lays out (the arrow keys move up and down by it).
    var columns = 12
    /// Set to open Search with the picker (the hotkey); Search empties it once it has.
    @Published var requested = false

    private(set) var query = ""
    private var loading = false

    private init() {
        tone = UserDefaults.standard.integer(forKey: Self.toneKey)
    }

    /// Every emoji in order, as the arrow keys go through them.
    var flat: [Emoji] { sections.flatMap(\.emoji) }

    var current: Emoji? {
        let all = flat
        return all.indices.contains(selected) ? all[selected] : nil
    }

    /// Opens Search with the picker in it.
    func open() {
        requested = true
        NotchPresenter.shared.primary?.open(tab: .ask, reason: .keyboard)
    }

    /// What's typed after the ":" (nothing: every group, with the ones used most first).
    func update(_ text: String) {
        query = text
        load()
        rebuild()
    }

    func move(_ delta: Int) {
        let count = flat.count
        guard count > 0 else { return }
        selected = min(max(selected + delta, 0), count - 1)
    }

    /// ⌘C copies the highlighted emoji while the picker is up.
    func handle(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard AssistantStore.shared.pickingEmoji, modifiers.intersection([.command, .option, .control, .shift]) == .command,
              key.lowercased() == "c", let emoji = current else { return false }
        copy(emoji)
        return true
    }

    func cycleTone() {
        tone = (tone + 1) % 6
    }

    /// Types it where you were (the notch closes).
    func insert(_ emoji: Emoji) {
        let text = emoji.toned(tone)
        noteUsed(emoji)
        TextInsertion.insert(text)
    }

    func copy(_ emoji: Emoji) {
        let text = emoji.toned(tone)
        noteUsed(emoji)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NotchPresenter.shared.primary?.close()
        ActivityCenter.shared.show(.notice(title: "Copied \(text)", detail: emoji.name.capitalizedFirst, icon: "doc.on.doc"), for: 2)
    }

    // MARK: - Sections

    private func rebuild() {
        guard let catalog else { sections = []; return }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            let frequent = frequentlyUsed(in: catalog)
            sections = (frequent.isEmpty ? [] : [Section(id: "frequent", title: "Frequently Used", emoji: frequent)])
                + catalog.groups.map { Section(id: $0.name, title: $0.name, emoji: $0.emoji) }
        } else {
            sections = [Section(id: "results", title: nil, emoji: catalog.search(q, boost: usageBoosts()))]
        }
        selected = 0
        generation += 1
    }

    /// Where each group starts in `flat`, for jumping to it.
    func start(of sectionID: String) -> Int? {
        var i = 0
        for s in sections {
            if s.id == sectionID { return i }
            i += s.emoji.count
        }
        return nil
    }

    // MARK: - Loading

    /// The list, read once, in the background: without the emoji this Mac's font can't draw
    /// (ones newer than its macOS), which would show as empty boxes.
    private func load() {
        guard catalog == nil, !loading, let url = Bundle.main.url(forResource: "Emoji", withExtension: "json") else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url), let full = try? EmojiCatalog(json: data) else { return }
            let drawable = full.filtered { group, emoji in group.name == "Characters" || Self.canDraw(emoji.character) }
            await MainActor.run {
                let picker = EmojiPicker.shared
                picker.catalog = drawable
                picker.loading = false
                picker.rebuild()
            }
        }
    }

    /// One glyph in Apple Color Emoji: the font has it (a sequence it doesn't know falls apart
    /// into several, or the missing-glyph box).
    nonisolated private static func canDraw(_ s: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        guard CTLineGetGlyphCount(line) == 1, let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return false }
        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        // A run in another font is a fallback: Apple Color Emoji didn't have it.
        guard let value = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] else { return false }
        let runFont = value as! CTFont
        return glyph != 0 && (CTFontCopyPostScriptName(runFont) as String) == "AppleColorEmoji"
    }

    // MARK: - What gets used

    private static let toneKey = "emoji.tone"
    private static let usageKey = "emoji.usage"

    /// Per emoji: how often it's been picked and when last.
    private lazy var usage: [String: [Double]] = UserDefaults.standard.dictionary(forKey: Self.usageKey) as? [String: [Double]] ?? [:]

    private func noteUsed(_ emoji: Emoji) {
        let old = usage[emoji.character] ?? [0, 0]
        usage[emoji.character] = [old[0] + 1, Date().timeIntervalSince1970]
        if usage.count > 300 {
            for key in usage.sorted(by: { $0.value[1] < $1.value[1] }).prefix(usage.count - 300).map(\.key) { usage[key] = nil }
        }
        UserDefaults.standard.set(usage, forKey: Self.usageKey)
    }

    /// Often and lately: each use counts for less as weeks go by.
    private func weight(_ entry: [Double], now: Double) -> Double {
        let days = max(0, now - (entry.count > 1 ? entry[1] : 0)) / 86_400
        return (entry.first ?? 0) * pow(0.5, days / 21)
    }

    /// Two rows' worth, most used first.
    private func frequentlyUsed(in catalog: EmojiCatalog) -> [Emoji] {
        let now = Date().timeIntervalSince1970
        return usage.sorted { weight($0.value, now: now) > weight($1.value, now: now) }
            .prefix(columns * 2)
            .compactMap { catalog.emoji($0.key) }
    }

    /// Up to 12 points, enough to order equal matches ("heart": yours first) and no more.
    private func usageBoosts() -> [String: Int] {
        let now = Date().timeIntervalSince1970
        return usage.mapValues { Int(min(12, 4 * log2(1 + weight($0, now: now))).rounded()) }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
