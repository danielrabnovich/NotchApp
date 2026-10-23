import SwiftUI

/// What Home can show: cards in a row across it.
enum HomeCard: String, Codable, CaseIterable {
    case music, today, weather, stats, batteries, clock, agents, shelf, timer, clipboard, unread, scratchpad, network, countdown

    /// A tile of its own at this size (narrow, and half height when small), rather than a column of
    /// the page.
    func isTile(_ size: HomeCardSize) -> Bool {
        switch self {
        case .today: false
        case .music, .weather: size == .small
        case .stats, .batteries, .clock, .agents, .shelf, .timer, .clipboard, .unread, .scratchpad, .network, .countdown: true
        }
    }

    /// Half of Home's height at this size, so two stack in a column.
    func isHalf(_ size: HomeCardSize) -> Bool {
        size == .small
    }
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

/// Lays Home's cards out in one row of columns, in their order: each at the size it wants, two
/// half-height tiles side by side stacked in one column. When they don't all fit, the extras
/// (weather, stats, clock…) shrink, then music (unless it's playing big) shrinks to a tile, then
/// the extras wait for room, least important first; last, music gives up its half.
/// The day itself always stays. Sizes set by hand don't shrink.
enum HomeTiler {
    /// Between two columns of the page: 18 + a rule + 18.
    static let gap: CGFloat = 37
    /// Beside a tile, which is narrower: 14 + a rule + 14.
    static let tileGap: CGFloat = 29
    /// Between two tiles stacked in a column: 8 + a rule + 8.
    static let stackGap: CGFloat = 17
    /// The least a half-height tile can be; with less (a call bar above Home), tiles don't stack.
    static let halfMinimum: CGFloat = 52

    struct Placed: Equatable {
        let card: HomeCard
        let size: HomeCardSize
    }

    struct Column: Equatable {
        var cards: [Placed]
        /// Its width; nil takes what the fixed ones leave.
        var width: CGFloat?
        /// The space before it, with a rule in the middle.
        var gap: CGFloat = 0
        var id: String { cards.map(\.card.rawValue).joined(separator: "+") }
    }

    private struct Item {
        let entry: HomeEntry
        var size: HomeCardSize
        let wanted: HomeCardSize
    }

    /// `wanted` is each card's size when there's room (nil: it has nothing to show).
    static func tile(_ entries: [HomeEntry], width: CGFloat, height: CGFloat, wanted: (HomeCard) -> HomeCardSize?) -> [Column] {
        let stacks = (height - stackGap) / 2 >= halfMinimum
        var items: [Item] = entries.compactMap { entry in
            wanted(entry.card).map { Item(entry: entry, size: entry.size ?? $0, wanted: entry.size ?? $0) }
        }
        func fits() -> Bool { needed(columns(items, width: width, stacks: stacks)) <= width }
        // Least important first; among equals, the later one.
        func ascending(_ tier: (HomeCard) -> Bool) -> [HomeCard] {
            items.enumerated().filter { tier($0.element.entry.card) }
                .sorted { (importance($0.element.entry.card), -$0.offset) < (importance($1.element.entry.card), -$1.offset) }
                .map(\.element.entry.card)
        }
        func shrink(_ tier: (HomeCard) -> Bool) {
            for card in ascending(tier) where !fits() {
                guard let i = items.firstIndex(where: { $0.entry.card == card }), items[i].entry.size == nil else { continue }
                while !fits(), let size = smaller(card, than: items[i].size) { items[i].size = size }
            }
        }
        func remove(_ tier: (HomeCard) -> Bool) {
            // Ones sized by hand last.
            let order = ascending(tier).sorted { a, b in
                (items.first { $0.entry.card == a }?.entry.size != nil ? 1 : 0) < (items.first { $0.entry.card == b }?.entry.size != nil ? 1 : 0)
            }
            for card in order where !fits() { items.removeAll { $0.entry.card == card } }
        }
        let extra = { (card: HomeCard) in card != .music && card != .today }
        shrink(extra)
        // Music that isn't playing big becomes a tile before anything has to wait for room.
        if let i = items.firstIndex(where: { $0.entry.card == .music }), items[i].entry.size == nil, items[i].size != .large {
            while !fits(), let size = smaller(.music, than: items[i].size) { items[i].size = size }
        }
        remove(extra)
        shrink { $0 == .music }
        remove { $0 == .music }
        // What shrank to make room for something that went anyway grows back, most important first.
        for card in items.map(\.entry.card).sorted(by: { importance($0) > importance($1) }) {
            guard let i = items.firstIndex(where: { $0.entry.card == card }) else { continue }
            while items[i].size < items[i].wanted, let size = larger(card, than: items[i].size) {
                let before = items[i].size
                items[i].size = size
                if !fits() { items[i].size = before; break }
            }
        }
        return columns(items, width: width, stacks: stacks)
    }

    private static func columns(_ items: [Item], width: CGFloat, stacks: Bool) -> [Column] {
        var columns: [Column] = []
        for item in items {
            let placed = Placed(card: item.entry.card, size: item.size)
            if stacks, item.entry.card.isHalf(item.size), let last = columns.last, last.cards.count == 1,
               last.cards[0].card.isHalf(last.cards[0].size) {
                columns[columns.count - 1].cards.append(placed)
            } else {
                columns.append(Column(cards: [placed]))
            }
        }
        for i in columns.indices {
            let card = columns[i].cards[0]
            columns[i].width = fixedWidth(card.card, card.size, alone: columns.count == 1, width: width)
            guard i > 0 else { continue }
            let before = columns[i - 1].cards[0].card.isTile(columns[i - 1].cards[0].size), now = card.card.isTile(card.size)
            columns[i].gap = before || now ? tileGap : gap
        }
        return columns
    }

    private static func needed(_ columns: [Column]) -> CGFloat {
        columns.reduce(0) { sum, column in
            sum + column.gap + (column.width ?? column.cards.map { minWidth($0.card) }.max() ?? 0)
        }
    }

    private static func fixedWidth(_ card: HomeCard, _ size: HomeCardSize, alone: Bool, width: CGFloat) -> CGFloat? {
        switch card {
        case .music: alone ? nil : size == .large ? (width - gap) / 2 : size == .medium ? 170 : 112
        case .today: nil
        case .weather: size == .small ? 112 : 128
        case .stats, .batteries, .clock, .agents, .shelf, .timer, .clipboard, .unread, .scratchpad, .network, .countdown: 112
        }
    }

    private static func minWidth(_ card: HomeCard) -> CGFloat {
        card == .today ? 210 : 0
    }

    private static func importance(_ card: HomeCard) -> Int {
        switch card {
        case .today: 3
        case .music: 2
        case .weather: 1
        case .stats, .batteries, .clock, .agents, .shelf, .timer, .clipboard, .unread, .scratchpad, .network, .countdown: 0
        }
    }

    /// The next size down, nil when it has none.
    private static func smaller(_ card: HomeCard, than size: HomeCardSize) -> HomeCardSize? {
        switch card {
        case .today: nil
        case .music: size == .large ? .medium : size == .medium ? .small : nil
        case .weather, .stats, .batteries, .clock, .agents, .shelf, .timer, .clipboard, .unread, .scratchpad, .network, .countdown: size == .medium ? .small : nil
        }
    }

    private static func larger(_ card: HomeCard, than size: HomeCardSize) -> HomeCardSize? {
        switch card {
        case .today: nil
        case .music: size == .small ? .medium : size == .medium ? .large : nil
        case .weather, .stats, .batteries, .clock, .agents, .shelf, .timer, .clipboard, .unread, .scratchpad, .network, .countdown: size == .small ? .medium : nil
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

extension HomeCard {
    var title: String {
        switch self {
        case .music: "Music"
        case .today: "Today"
        case .weather: "Weather"
        case .stats: "Stats"
        case .batteries: "Batteries"
        case .clock: "World Clock"
        case .agents: "Agents"
        case .shelf: "Shelf"
        case .timer: "Timer"
        case .clipboard: "Clipboard"
        case .unread: "Unread"
        case .scratchpad: "Scratchpad"
        case .network: "Network"
        case .countdown: "Countdown"
        }
    }

    var icon: String {
        switch self {
        case .music: "music.note"
        case .today: "calendar"
        case .weather: "cloud.sun.fill"
        case .stats: "gauge.with.dots.needle.50percent"
        case .batteries: "battery.75percent"
        case .clock: "globe"
        case .agents: "sparkles.rectangle.stack.fill"
        case .shelf: "tray.full.fill"
        case .timer: "timer"
        case .clipboard: "doc.on.clipboard"
        case .unread: "app.badge"
        case .scratchpad: "note.text"
        case .network: "network"
        case .countdown: "hourglass"
        }
    }

    var summary: String {
        switch self {
        case .music: "What's playing, with its controls. Gone when nothing is."
        case .today: "Your week, today's events, birthdays and what's due."
        case .weather: "The weather now and the next few days."
        case .stats: "How busy the Mac is: CPU, GPU and memory."
        case .batteries: "The Mac's battery and your Bluetooth devices', emptiest first."
        case .clock: "The time in another city."
        case .agents: "Your coding agents: which are working, and which are waiting for you."
        case .shelf: "The latest files on the Shelf, to drag straight into another app."
        case .timer: "Start a countdown or a focus session, and see it run."
        case .clipboard: "What you copied last: click one to copy it again."
        case .unread: "Unread counts from the Dock: Mail, Slack, Messages and the rest."
        case .scratchpad: "A note to type into right on Home."
        case .network: "How fast it's going right now, and whether a VPN is on."
        case .countdown: "Days to go until a date you pick."
        }
    }

    /// The sizes it can be set to, smallest first (none: it takes what's left).
    var sizes: [HomeCardSize] {
        switch self {
        case .today: []
        case .music: [.small, .medium, .large]
        case .weather, .stats, .batteries, .clock, .agents, .shelf, .timer, .clipboard, .unread, .scratchpad, .network, .countdown: [.small, .medium]
        }
    }

    func name(_ size: HomeCardSize) -> String {
        switch (self, size) {
        case (.music, .small): "Tile"
        case (.music, .medium): "Card"
        case (.music, _): "Half of Home"
        case (_, .small): "Half height"
        default: "Full height"
        }
    }
}

extension HomeCard {
    /// Whether the feature it shows is on; a card for one that's off waits until it is.
    @MainActor func isOn(_ s: AppSettings) -> Bool {
        switch self {
        case .music: s.musicEnabled
        case .today: s.calendarEnabled || s.tasksEnabled
        case .stats: s.statsEnabled
        case .agents: s.agentsEnabled
        case .shelf: s.shelfEnabled
        case .timer: s.timerEnabled
        case .clipboard: s.clipboardHistory
        case .weather, .batteries, .clock, .unread, .scratchpad, .network, .countdown: true
        }
    }

    /// Where its feature is turned on, for a card that's off.
    var featureHint: String {
        switch self {
        case .music: "Turn on the music player"
        case .today: "Turn on Calendar or Tasks"
        case .clipboard: "Turn on Clipboard history in Shelf"
        default: "Turn on \(title) in Add-ons"
        }
    }
}
