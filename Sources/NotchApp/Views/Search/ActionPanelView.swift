import SwiftUI

/// The ⌘K list: everything that can be done to the highlighted result, each with its shortcut,
/// over the bottom right of the results. Typing filters it, ↩ runs, esc or ⌘K closes.
struct ActionPanelView: View {
    @ObservedObject var panel: ActionPanel
    @FocusState private var focused: Bool

    static let width: CGFloat = 292
    private static let rowHeight: CGFloat = 26
    /// The line between groups, with the space around it.
    private static let dividerHeight: CGFloat = 7
    /// Five rows and a sliver of the sixth, so a longer list shows that it scrolls.
    private static let listHeight: CGFloat = rowHeight * 5.4
    private static let radius: CGFloat = 14
    private static let inset: CGFloat = 4

    var body: some View {
        let shown = panel.shown
        VStack(spacing: 0) {
            if shown.isEmpty {
                Text("No matching actions")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight * 2)
            } else {
                list(shown)
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, -Self.inset)
            filterField
        }
        .padding(Self.inset)
        .frame(width: Self.width)
        .notchSurface(RoundedRectangle(cornerRadius: Self.radius, style: .continuous), active: true)
        // Solid under the surface's light tint: it sits over the results, which would show through.
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color(white: 0.085)))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func list(_ shown: [ItemAction]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, action in
                    VStack(spacing: 0) {
                        // A line between groups (Open…, then Quit…, then Copy…).
                        if Self.startsGroup(shown, i) {
                            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                                .padding(.horizontal, 6).padding(.vertical, (Self.dividerHeight - 1) / 2)
                        }
                        row(action, highlighted: i == panel.selected)
                            .contentShape(Rectangle())
                            .onHover { if $0 { panel.selected = i } }
                            .onTapGesture { panel.run(action) }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $topRow, anchor: .top)
        .frame(height: Self.viewport(shown))
        // Only the arrow keys scroll: a row sliding under a still pointer would take the highlight.
        .onChange(of: panel.moves) { reveal(panel.selected, in: shown) }
        .onChange(of: panel.filter) { topRow = nil }
        .transaction { $0.animation = nil }
    }

    /// The row at the top of the list, as the scroll view has it.
    @State private var topRow: ItemAction.ID?

    /// Scrolls just enough to show row `i` whole, with a whole row at the top. Worked out from the
    /// rows' fixed heights: asked to scroll a row into view, the scroll view stopped short of the
    /// last ones.
    private func reveal(_ i: Int, in shown: [ItemAction]) {
        guard shown.indices.contains(i) else { return }
        let tops = Self.tops(shown)
        let first = topRow.flatMap { id in shown.firstIndex { $0.id == id } } ?? 0
        let viewport = Self.viewport(shown)
        if tops[i] < tops[first] {
            topRow = shown[i].id
        } else if tops[i + 1] > tops[first] + viewport {
            // The first row from which row i still fits.
            var k = i
            while k > 0, tops[i + 1] - tops[k - 1] <= viewport { k -= 1 }
            topRow = shown[k].id
        }
    }

    /// Where each row (with the line above it, if any) starts, and lastly where the list ends.
    private static func tops(_ shown: [ItemAction]) -> [CGFloat] {
        var y: CGFloat = 0
        return shown.indices.map { i in
            defer { y += rowHeight + (startsGroup(shown, i) ? dividerHeight : 0) }
            return y
        } + [CGFloat(shown.count) * rowHeight + CGFloat(shown.indices.filter { startsGroup(shown, $0) }.count) * dividerHeight]
    }

    private static func viewport(_ shown: [ItemAction]) -> CGFloat {
        min(tops(shown).last ?? 0, listHeight)
    }

    private static func startsGroup(_ shown: [ItemAction], _ i: Int) -> Bool {
        i > 0 && shown[i - 1].group != shown[i].group
    }

    private func row(_ action: ItemAction, highlighted: Bool) -> some View {
        let red = Color(nsColor: .systemRed)
        return HStack(spacing: 8) {
            Image(systemName: action.icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(highlighted ? .white : action.destructive ? red : .white.opacity(0.7))
            Text(action.title)
                .font(.system(size: 12.5))
                .foregroundStyle(highlighted ? .white : action.destructive ? red : .white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let key = action.key { KeyCap(text: key.display, onAccent: highlighted) }
        }
        .padding(.horizontal, 7)
        .frame(height: Self.rowHeight)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: Self.radius - Self.inset, style: .continuous)
                    .fill(action.destructive ? AnyShapeStyle(red.gradient) : AnyShapeStyle(Color.accentColor.gradient))
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 7) {
            if let icon = panel.target?.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "command").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    .frame(width: 16)
            }
            TextField("", text: $panel.filter, prompt: Text("Actions for \(panel.target?.title ?? "this")")
                .foregroundStyle(.white.opacity(0.32)))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onKeyPress(.downArrow) { panel.move(1); return .handled }
                .onKeyPress(.upArrow) { panel.move(-1); return .handled }
                .onSubmit { panel.runSelected() }
                .onExitCommand { panel.close() }
            KeyCap(text: "⌘K")
        }
        .padding(.horizontal, 7)
        .frame(height: 32)
    }
}
