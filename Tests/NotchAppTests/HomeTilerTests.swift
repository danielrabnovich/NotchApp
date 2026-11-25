import CoreGraphics
import Testing
@testable import NotchApp

/// Home's tiler: what fits, what shrinks and what waits, at the open notch's sizes.
@MainActor
struct HomeTilerTests {
    /// The open notch's Home on most Macs, and on the wider ones.
    private let narrow: CGFloat = 644, wide: CGFloat = 704, height: CGFloat = 144

    private func tile(_ entries: [HomeEntry], width: CGFloat? = nil, height: CGFloat? = nil,
                      wanted: [HomeCard: HomeCardSize] = [:]) -> [HomeTiler.Placed] {
        HomeTiler.tile(entries, width: width ?? narrow, height: height ?? self.height) { card in
            wanted[card] ?? (card == .today ? .large : .medium)
        }.flatMap(\.cards)
    }

    private func entries(_ cards: HomeCard...) -> [HomeEntry] { cards.map { HomeEntry(card: $0) } }

    @Test func defaultsFitAsTheyAre() {
        let placed = tile(HomeEntry.defaults)
        #expect(placed.map(\.card) == [.music, .today, .weather])
        #expect(placed.first { $0.card == .weather }?.size == .medium)
    }

    @Test func keepsTheOrder() {
        let placed = tile(entries(.weather, .today, .stats))
        #expect(placed.map(\.card) == [.weather, .today, .stats])
    }

    @Test func cardsWithNothingToShowAreLeftOut() {
        let placed = HomeTiler.tile(entries(.music, .today, .github), width: narrow, height: height) { card in
            card == .github ? nil : .medium
        }.flatMap(\.cards)
        #expect(!placed.contains { $0.card == .github })
    }

    @Test func theDayAlwaysStays() {
        // Far too many cards for the room: extras go, the day never does.
        for width in [CGFloat(300), narrow, wide] {
            let placed = tile(entries(.music, .today, .weather, .stats, .clock, .batteries, .timer, .network), width: width)
            #expect(placed.contains { $0.card == .today }, "width \(width)")
        }
    }

    @Test func everythingPlacedFitsTheWidth() {
        let all = HomeCard.allCases.map { HomeEntry(card: $0) }
        for width in [narrow, wide] {
            let columns = HomeTiler.tile(all, width: width, height: height) { $0 == .today ? .large : .medium }
            let used = columns.reduce(CGFloat(0)) { $0 + $1.gap + ($1.width ?? 210) }
            #expect(used <= width, "width \(width): \(used)")
        }
    }

    @Test func extrasShrinkBeforeTheyWait() {
        // Three medium extras beside music and the day don't fit at full size: they shrink to
        // half-height tiles, stacked two to a column, rather than going.
        let placed = tile(entries(.music, .today, .weather, .stats, .clock))
        let extras = placed.filter { [.weather, .stats, .clock].contains($0.card) }
        #expect(extras.contains { $0.size == .small })
        #expect(placed.contains { $0.card == .today })
    }

    @Test func halvesDontStackWithoutHeight() {
        // A call bar above Home leaves too little height for two half tiles in a column.
        let columns = HomeTiler.tile(entries(.today, .stats, .clock), width: narrow, height: 100) { card in
            card == .today ? .large : .small
        }
        #expect(columns.allSatisfy { $0.cards.count == 1 })
    }

    @Test func aCardSizedByHandStaysWhileMusicPlaysBig() {
        // Music playing big, and Stats given a size by hand: music gives up its half for Stats.
        var cards = entries(.music, .today, .weather, .stats)
        cards[3].size = .medium
        let placed = tile(cards, wanted: [.music: .large])
        #expect(placed.first { $0.card == .stats }?.size == .medium)
        #expect(placed.contains { $0.card == .today })
        #expect(placed.first { $0.card == .music }.map { $0.size < .large } ?? true)
    }

    @Test func autoCardsWaitForMusicPlayingBig() {
        // Left to Auto, the extras make room for the player instead.
        let placed = tile(entries(.music, .today, .weather, .stats, .clock), wanted: [.music: .large])
        #expect(placed.first { $0.card == .music }?.size == .large)
        #expect(placed.contains { $0.card == .today })
    }
}
