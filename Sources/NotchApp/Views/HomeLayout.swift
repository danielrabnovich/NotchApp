import SwiftUI

/// What Home can show: cards in a row across it.
enum HomeCard: String, Codable, CaseIterable {
    case music, today, weather
}

/// How much of Home a card takes. Not every card has every size.
enum HomeCardSize: String, Codable, Comparable {
    case small, medium, large

    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    private var rank: Int { [.small: 0, .medium: 1, .large: 2][self]! }
}

/// A card on Home, and the size it was given by hand (nil: whatever fits).
struct HomeEntry: Codable, Equatable {
    var card: HomeCard
    var size: HomeCardSize?

    static let defaults: [HomeEntry] = [.init(card: .music), .init(card: .today), .init(card: .weather)]
}

/// Lays Home's cards out in one row: each at the size it wants, and when they don't all fit, the
/// least important one shrinks or goes first (the weather, then music), sizes set by hand last.
enum HomeTiler {
    /// The space a card and the rule before it take: 18 + 1 + 18.
    static let gap: CGFloat = 37

    struct Placed: Equatable {
        let card: HomeCard
        let size: HomeCardSize
        /// Its width; nil takes what the fixed ones leave.
        let width: CGFloat?
    }

    /// `wanted` is each card's size when there's room (nil: it has nothing to show).
    static func tile(_ entries: [HomeEntry], width: CGFloat, wanted: (HomeCard) -> HomeCardSize?) -> [Placed] {
        var cards: [(entry: HomeEntry, size: HomeCardSize)] = entries.compactMap { entry in
            wanted(entry.card).map { (entry, entry.size ?? $0) }
        }
        while needed(cards.map { ($0.entry.card, $0.size) }, width: width) > width {
            // Least important first; a size set by hand only once nothing else can give.
            let rank = { (i: Int) in (cards[i].entry.size == nil ? 0 : 1, priority(cards[i].entry.card)) }
            let order = cards.indices.sorted { rank($0) < rank($1) }
            guard let i = order.first(where: { smaller(cards[$0].entry.card, than: cards[$0].size) != .some(cards[$0].size) }) else { break }
            if let size = smaller(cards[i].entry.card, than: cards[i].size) { cards[i].size = size } else { cards.remove(at: i) }
        }
        let sized = cards.map { ($0.entry.card, $0.size) }
        return sized.map { Placed(card: $0.0, size: $0.1, width: fixedWidth($0.0, $0.1, alone: sized.count == 1, width: width)) }
    }

    private static func needed(_ cards: [(HomeCard, HomeCardSize)], width: CGFloat) -> CGFloat {
        cards.reduce(gap * CGFloat(max(0, cards.count - 1))) { sum, card in
            sum + (fixedWidth(card.0, card.1, alone: cards.count == 1, width: width) ?? minWidth(card.0))
        }
    }

    private static func fixedWidth(_ card: HomeCard, _ size: HomeCardSize, alone: Bool, width: CGFloat) -> CGFloat? {
        switch card {
        case .music: alone ? nil : size == .large ? (width - gap) / 2 : 170
        case .today: nil
        case .weather: 128
        }
    }

    private static func minWidth(_ card: HomeCard) -> CGFloat {
        switch card {
        case .today: 220
        case .music, .weather: 0
        }
    }

    private static func priority(_ card: HomeCard) -> Int {
        switch card {
        case .weather: 0
        case .music: 1
        case .today: 2
        }
    }

    /// The next size down, nil when the card goes instead, or the same size when it can't give.
    private static func smaller(_ card: HomeCard, than size: HomeCardSize) -> HomeCardSize? {
        switch card {
        case .music: size == .large ? .small : size
        case .today: size
        case .weather: nil
        }
    }
}

/// How the day fits Home's height: a call bar above it, or a birthday line, can leave too little
/// room for even one event. First the week strip loses its weekday letters (the weather beside it
/// shrinks to match), then the birthday line goes.
struct HomeFit: Equatable {
    /// The month and week strip's line, which the weather beside it lines up with.
    var headerHeight: CGFloat = Self.fullHeader
    var birthdayLine = true

    var letters: Bool { headerHeight == Self.fullHeader }

    static let fullHeader: CGFloat = 45
    static let shortHeader: CGFloat = 36
    /// Under the header: its gap, then one whole event row.
    private static let oneRow: CGFloat = 10 + 30
    /// The birthday line and the gap under it.
    private static let birthday: CGFloat = 15 + 8

    static func fitting(height: CGFloat, birthday hasBirthday: Bool) -> HomeFit {
        let line = hasBirthday ? birthday : 0
        if height >= fullHeader + line + oneRow { return HomeFit() }
        if height >= shortHeader + line + oneRow { return HomeFit(headerHeight: shortHeader) }
        return HomeFit(headerHeight: shortHeader, birthdayLine: false)
    }
}
