import NotchKit
import SwiftUI

/// Emoji and characters under the search bar (":" then a name): a grid on the left, the
/// highlighted one large on the right with its name, skin tone and what ↩ does.
struct EmojiPickerView: View {
    @ObservedObject var picker: EmojiPicker

    private static let cell: CGFloat = 32
    static let radius: CGFloat = 16
    static let inset: CGFloat = 5

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                if picker.query.trimmingCharacters(in: .whitespaces).isEmpty, picker.catalog != nil { groupBar }
                grid
            }
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1).padding(.vertical, 4)
            preview
                .frame(width: 168)
        }
        .padding(Self.inset)
        .notchSurface(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
    }

    // MARK: - Grid

    private var grid: some View {
        GeometryReader { geo in
            let columns = max(1, Int(geo.size.width / Self.cell))
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // Columns share the width, so the grid fills it edge to edge.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: columns),
                              alignment: .leading, spacing: 0) {
                        ForEach(indexedSections, id: \.section.id) { entry in
                            Section {
                                ForEach(Array(entry.section.emoji.enumerated()), id: \.element.id) { i, emoji in
                                    cell(emoji, index: entry.start + i)
                                }
                            } header: {
                                if let title = entry.section.title { header(title).id("section:" + entry.section.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)
                    .id(picker.generation)
                }
                .overlay {
                    if picker.catalog != nil, picker.flat.isEmpty {
                        Text("No emoji match “\(picker.query)”")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    }
                }
                .onAppear { picker.columns = columns }
                .onChange(of: columns) { _, n in picker.columns = n }
                .onChange(of: picker.selected) { _, i in proxy.scrollTo(i) }
                .onChange(of: jump) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.small.animation) { proxy.scrollTo("section:" + id, anchor: .top) }
                    jump = nil
                }
            }
        }
    }

    /// A group picked in the bar above: the grid scrolls to it.
    @State private var jump: String?

    private var indexedSections: [(section: EmojiPicker.Section, start: Int)] {
        var start = 0
        return picker.sections.map { s in
            defer { start += s.emoji.count }
            return (s, start)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func cell(_ emoji: Emoji, index: Int) -> some View {
        let highlighted = index == picker.selected
        return Text(emoji.toned(picker.tone))
            .font(.system(size: 21))
            .frame(width: Self.cell, height: Self.cell)
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.gradient)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { if $0 { picker.selected = index } }
            .onTapGesture { picker.insert(emoji) }
            .help(emoji.name)
            .id(index)
    }

    // MARK: - Groups

    private var groupBar: some View {
        HStack(spacing: 2) {
            ForEach(picker.sections) { section in
                let active = activeSection == section.id
                Button {
                    if let start = picker.start(of: section.id) { picker.selected = start }
                    jump = section.id
                } label: {
                    Image(systemName: Self.icon(section.id))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(active ? 0.95 : 0.4))
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.barHeight)
                        .background {
                            // Concentric with the surface's corner, the same gap above as beside.
                            if active {
                                RoundedRectangle(cornerRadius: Self.radius - Self.inset, style: .continuous)
                                    .fill(.white.opacity(0.1))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(section.title ?? "")
            }
        }
    }

    private static let barHeight: CGFloat = 26

    /// The group the highlighted emoji is in.
    private var activeSection: String? {
        indexedSections.last { $0.start <= picker.selected }?.section.id
    }

    private static func icon(_ id: String) -> String {
        switch id {
        case "frequent": "clock"
        case "Smileys": "face.smiling"
        case "People": "hand.wave"
        case "Nature": "leaf"
        case "Food": "fork.knife"
        case "Travel": "car"
        case "Activities": "basketball"
        case "Objects": "lightbulb"
        case "Symbols": "heart"
        case "Flags": "flag"
        case "Characters": "command"
        default: "circle"
        }
    }

    // MARK: - Preview

    @ViewBuilder private var preview: some View {
        if let emoji = picker.current {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Text(emoji.toned(picker.tone))
                    .font(.system(size: 46))
                    .frame(height: 54)
                    .contentTransition(.identity)
                Text(emoji.name.prefix(1).uppercased() + emoji.name.dropFirst())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if !emoji.keywords.isEmpty {
                    Text(emoji.keywords.prefix(5).joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.38))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
                if emoji.tones != nil { tones(emoji) }
                Spacer(minLength: 0)
                hints
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        } else {
            Color.clear
        }
    }

    /// The six choices, shown on this emoji: click one, or ⇥ to go through them.
    private func tones(_ emoji: Emoji) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<6, id: \.self) { t in
                Button { picker.tone = t } label: {
                    Text(emoji.toned(t))
                        .font(.system(size: 13))
                        .frame(width: 22, height: 22)
                        .background {
                            if t == picker.tone {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: 1.2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "↩ Type in Notes  ⌘C Copy", or just "↩ Type" when the app's name doesn't fit.
    private var hints: some View {
        let app = FrontmostTracker.shared.userApp?.localizedName
        return ViewThatFits(in: .horizontal) {
            if let app { hintRow("Type in \(app)") }
            hintRow("Type")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
    }

    private func hintRow(_ type: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                KeyCap(text: "↩")
                Text(type)
            }
            HStack(spacing: 3) {
                KeyCap(text: "⌘C")
                Text("Copy")
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}
