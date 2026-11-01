import Foundation
import NotchKit
import Testing

struct EmojiCatalogTests {
    /// The real list, as the app ships it.
    static let catalog: EmojiCatalog = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Emoji.json")
        return try! EmojiCatalog(json: Data(contentsOf: url))
    }()

    @Test("Best match first", arguments: [
        ("fire", "🔥"), ("thumb", "👍"), ("thumbs up", "👍"), ("+1", "👍"), ("tada", "🎉"), ("uk", "🇬🇧"), ("gb", "🇬🇧"),
        ("red heart", "❤️"), ("heart red", "❤️"), ("cmd", "⌘"), ("rocket", "🚀"), ("thinking", "🤔"),
    ])
    func top(query: String, expected: String) {
        #expect(Self.catalog.search(query).first?.character == expected)
    }

    @Test("Emoticons", arguments: [(":)", "🙂"), (")", "🙂"), ("<3", "❤️"), (";)", "😉"), ("xD", "😆")])
    func emoticons(typed: String, expected: String) {
        #expect(Self.catalog.search(typed).first?.character == expected)
    }

    @Test func tones() throws {
        let thumbs = try #require(Self.catalog.emoji("👍"))
        #expect(thumbs.toned(0) == "👍")
        #expect(thumbs.toned(3) == "👍🏽")
        let fire = try #require(Self.catalog.emoji("🔥"))
        #expect(fire.tones == nil)
        #expect(fire.toned(3) == "🔥")
    }

    @Test func groupsInKeyboardOrder() {
        #expect(Self.catalog.groups.map(\.name) == ["Smileys", "People", "Nature", "Food", "Travel", "Activities",
                                                    "Objects", "Symbols", "Flags", "Characters"])
        #expect(Self.catalog.groups.first?.emoji.first?.character == "😀")
    }

    @Test func boostOrdersEquals() {
        let plain = Self.catalog.search("heart").prefix(5).map(\.character)
        let boosted = Self.catalog.search("heart", boost: ["💜": 30]).first?.character
        #expect(boosted == "💜")
        #expect(plain.first != "💜")
    }

    @Test func nothingForNonsense() {
        #expect(Self.catalog.search("zzqxj").isEmpty)
        #expect(Self.catalog.search("").isEmpty)
    }

    @Test func filteredDropsEmptyGroups() {
        let onlyChars = Self.catalog.filtered { g, _ in g.name == "Characters" }
        #expect(onlyChars.groups.map(\.name) == ["Characters"])
    }
}
