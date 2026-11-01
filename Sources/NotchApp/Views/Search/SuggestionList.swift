import SwiftUI

/// Results as you type: an instant answer, apps, files, and the full search. Arrow keys move,
/// Return acts on the highlighted row.
struct SuggestionList: View {
    let items: [Suggestion]
    /// Rows held for file matches still loading.
    var placeholders = 0
    @Binding var selected: Int
    let copied: String?
    let perform: (Suggestion) -> Void
    @EnvironmentObject private var assistant: AssistantStore

    private let rowHeight: CGFloat = 30
    /// The list's surface corner and the padding inside it. The highlight sits concentric
    /// within: its radius is the outer radius minus the inset.
    static let radius: CGFloat = 16
    static let inset: CGFloat = 5
    private static let highlightRadius = radius - inset

    var body: some View {
        // Rows are keyed by position and the highlight is one layer behind them: the list changes
        // on every keystroke ("Search for …" is a new item each time), and per-item identity made
        // the highlight fade out and back in as you typed.
        // The full "/" command list is taller than the notch: show six rows and scroll the rest,
        // instead of pushing the search bar up out of view.
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        row(item, highlighted: i == selected)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = i; perform(item) }
                            .onHover { if $0 { selected = i } }
                            .id(i)
                    }
                    ForEach(0..<placeholders, id: \.self) { i in
                        PlaceholderRow(index: i).frame(height: rowHeight)
                    }
                }
                .background(alignment: .top) {
                    if items.indices.contains(selected) {
                        RoundedRectangle(cornerRadius: Self.highlightRadius, style: .continuous)
                            .fill(Color.accentColor.gradient)
                            .frame(height: rowHeight)
                            .offset(y: CGFloat(selected) * rowHeight)
                    }
                }
            }
            .scrollDisabled(items.count <= Self.maxRows)
            // Up to its rows' height, and no taller than the room under the bar: the notch grows to
            // fit new rows with a spring, and a list already at full height overflowed the page until
            // it caught up, which pushed the bar up and back (rows coming in on the third key or so).
            .frame(minHeight: 0, maxHeight: CGFloat(min(items.count + placeholders, Self.maxRows)) * rowHeight, alignment: .top)
            .clipped()
            .onChange(of: selected) { _, i in proxy.scrollTo(i) }
        }
        .transaction { $0.animation = nil }
    }

    private static let maxRows = SearchSuggestions.maxRows

    /// One line per result, like Spotlight: icon, name, a dimmer detail, and the action on the selected row.
    @ViewBuilder private func row(_ item: Suggestion, highlighted: Bool) -> some View {
        HStack(spacing: 9) {
            icon(item, highlighted: highlighted)
                .frame(width: 20, height: 20)
            // A long query truncates the title; the detail drops out rather than shrinking to a letter.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    titleText(item)
                    if let sub = subtitle(item) {
                        Text(sub)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(highlighted ? 0.7 : 0.38))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // Ideal width small, so a long detail (a definition) truncates into
                            // the room there is instead of the whole detail being dropped.
                            .frame(minWidth: 90, idealWidth: 90, maxWidth: .infinity, alignment: .leading)
                    }
                }
                titleText(item)
            }
            Spacer(minLength: 8)
            if highlighted {
                HStack(spacing: 5) {
                    if case .file = item {
                        KeyCap(text: "⌘Y", onAccent: true)
                        Text("Preview").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                            .padding(.trailing, 4)
                    }
                    Text(hint(item))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    if !(item.isAnswer && copied == title(item)) { KeyCap(text: "↩", onAccent: true) }
                    if item.hasActions { KeyCap(text: "⌘K", onAccent: true).padding(.leading, 3) }
                }
                // The action keeps its size however long the query gets.
                .fixedSize()
                .layoutPriority(2)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: rowHeight)
    }

    private func titleText(_ item: Suggestion) -> some View {
        Text(title(item))
            .font(.system(size: item.isAnswer ? 15 : 13, weight: item.isAnswer ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(.white.opacity(0.95))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder private func icon(_ item: Suggestion, highlighted: Bool) -> some View {
        switch item {
        case .answer(let a):
            Image(systemName: a.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(highlighted ? 1 : 0.8))
        case .app(let app):
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable()
        case .file(let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        case .search:
            Image(systemName: assistant.aiAvailable ? "sparkle.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(highlighted ? 1 : 0.65))
        case .command(let c):
            if case .quitApp(let pid) = c.action, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                Image(nsImage: icon).resizable()
            } else {
                // In what it does' colour; white on the highlight, which is the accent colour.
                Image(systemName: c.icon).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(highlighted ? AnyShapeStyle(.white) : c.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.white.opacity(0.75)))
            }
        case .plan:
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(highlighted ? 1 : 0.75))
        case .doInApp:
            if let icon = AppActions.shared.context.flatMap({ NSRunningApplication(processIdentifier: $0.pid)?.icon }) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(highlighted ? 1 : 0.75))
            }
        }
    }

    private func title(_ item: Suggestion) -> String {
        switch item {
        case .answer(let a): a.title
        case .app(let app): app.name
        case .file(let url): url.lastPathComponent
        case .search(let q): "Search for “\(q)”"
        case .command(let c): c.title
        case .plan: "Turn into tasks & notes"
        case .doInApp(let q, let app): "Do “\(q)” in \(app)"
        }
    }

    private func subtitle(_ item: Suggestion) -> String? {
        switch item {
        case .answer(let a): a.subtitle
        case .app: "Application"
        case .file(let url):
            ScreenshotText.shared.snippet(for: url, query: SearchSuggestions.shared.currentQuery).map { "Screenshot · “\($0)”" }
                ?? url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .search: assistant.aiAvailable ? "Files, web and weather, with AI" : "Files, web and weather"
        case .command(let c): c.subtitle
        case .plan: "AI drafts them, you review first"
        case .doInApp(_, let app): "Picks from \(app)'s menus and actions"
        }
    }

    private func hint(_ item: Suggestion) -> String {
        switch item {
        case .answer(let a): copied == a.title ? "Copied" : "Copy"
        case .app, .file: "Open"
        case .search: "Search"
        case .command(let c): c.verb
        case .plan: "Plan"
        case .doInApp: "Do it"
        }
    }
}

/// A skeleton row held for a file match that's still loading: an icon and a name-length bar,
/// gently pulsing. Driven by the clock rather than an animation, since the list turns animations off.
private struct PlaceholderRow: View {
    let index: Int

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * 2.6 - Double(index) * 0.7)
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 5, style: .continuous).frame(width: 20, height: 20)
                Capsule().frame(width: [150, 110, 170][index % 3], height: 9)
                Capsule().frame(width: [90, 120, 70][index % 3], height: 7).opacity(0.6)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.06 + 0.05 * pulse))
            .padding(.horizontal, 9)
        }
        .transition(.opacity)
    }
}

private extension Suggestion {
    var isAnswer: Bool { if case .answer = self { true } else { false } }
    /// ⌘K lists more for it (`ItemActions`).
    var hasActions: Bool {
        switch self {
        case .app, .file: true
        default: false
        }
    }
}
