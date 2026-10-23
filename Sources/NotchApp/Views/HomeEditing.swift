import SwiftUI

/// Home's edit mode, in the notch: each card outlined, to drag along the row, size or take off;
/// the header offers more cards and Done. The notch stays open while it's on (as it does while
/// typing); Esc, Done, another tab or closing the notch ends it.
@MainActor
final class HomeEditing: ObservableObject {
    static let shared = HomeEditing()
    @Published private(set) var active = false
    /// Showing the cards to add, in place of Home's own.
    @Published var adding = false
    /// Cards on Home that wait for room right now, for the header to say so.
    @Published var waiting: [HomeCard] = []

    func begin() {
        withAnimation(Motion.small.animation) { active = true }
        NotchPresenter.shared.primary?.isEditing = true
    }

    func end() {
        guard active else { return }
        withAnimation(Motion.small.animation) {
            active = false
            adding = false
        }
        NotchPresenter.shared.primary?.isEditing = false
    }
}

/// A card while Home is being edited: dimmed under its name, dashed, dragged sideways to move it,
/// with a button to take it off and one to step through its sizes. What's on the card doesn't
/// respond meanwhile.
struct HomeEditDecoration: ViewModifier {
    let entry: HomeEntry
    let editing: Bool
    let onDrag: (CGFloat) -> Void
    let onDrop: (CGFloat) -> Void
    @EnvironmentObject private var settings: AppSettings

    private var card: HomeCard { entry.card }

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!editing)
            .overlay {
                if editing {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.black.opacity(0.8))
                            .strokeBorder(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        // Name over size, or side by side in a half-height tile.
                        ViewThatFits(in: .vertical) {
                            VStack(spacing: 5) { name; size }
                            HStack(spacing: 8) { name; size }
                        }
                        .padding(.horizontal, 6)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { onDrag($0.translation.width) }
                            .onEnded { onDrop($0.translation.width) }
                    )
                    .overlay(alignment: .topLeading) { remove }
                    .help("Drag to move \(card.title)")
                    .transition(.opacity)
                }
            }
    }

    private var name: some View {
        HStack(spacing: 5) {
            Image(systemName: card.icon).font(.system(size: 12, weight: .semibold))
            Text(card.title).font(.system(size: 12, weight: .semibold))
        }
        .lineLimit(1)
    }

    @ViewBuilder private var size: some View {
        if !card.sizes.isEmpty {
            // Auto, then each size, then back to Auto.
            let options: [HomeCardSize?] = [nil] + card.sizes.map { $0 }
            Button {
                let next = options[((options.firstIndex(of: entry.size) ?? 0) + 1) % options.count]
                guard let i = settings.homeCards.firstIndex(where: { $0.card == card }) else { return }
                withAnimation(Motion.pane.animation) { settings.homeCards[i].size = next }
            } label: {
                HStack(spacing: 3) {
                    Text(entry.size.map { card.name($0) } ?? "Auto")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(Capsule().fill(.white.opacity(0.18)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Its size: Auto fits it to the room. Click for the next")
        }
    }

    private var remove: some View {
        Button {
            withAnimation(Motion.pane.animation) { settings.homeCards.removeAll { $0.card == card } }
        } label: {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 15))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(white: 0.32))
        }
        .buttonStyle(.plain)
        .padding(5)
        .help("Take \(card.title) off Home")
    }
}

/// The header while Home is being edited, in place of the battery and buttons: what's waiting for
/// room, more cards, and Done.
struct HomeEditBar: View {
    @ObservedObject private var editing = HomeEditing.shared
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            if !editing.waiting.isEmpty {
                Text(editing.waiting.count == 1 ? "\(editing.waiting[0].title) is waiting for room" : "\(editing.waiting.count) waiting for room")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .help(editing.waiting.map(\.title).joined(separator: ", ") + ": they come back when there's space")
            }
            if !HomeCard.allCases.allSatisfy({ card in settings.homeCards.contains { $0.card == card } }) || editing.adding {
                Button {
                    withAnimation(Motion.pane.animation) { editing.adding.toggle() }
                } label: {
                    Label(editing.adding ? "Back" : "Add", systemImage: editing.adding ? "chevron.left" : "plus")
                }
                .buttonStyle(NotchPillButtonStyle(primary: false, height: 22))
            }
            Button("Done") { editing.end() }
                .buttonStyle(NotchPillButtonStyle(primary: true, height: 22))
        }
        .padding(.trailing, 4)
    }
}

/// The cards not on Home yet, in place of Home's own while adding: click one to add it, and it
/// takes its place in the row (after the others). A card whose feature is off says where to turn
/// it on, and is added anyway, to show once it is.
struct HomeCardGallery: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var editing = HomeEditing.shared

    var body: some View {
        let missing = HomeCard.allCases.filter { card in !settings.homeCards.contains { $0.card == card } }
        if missing.isEmpty {
            Text("Every card is on Home")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(missing, id: \.self) { card in
                    Button {
                        withAnimation(Motion.pane.animation) {
                            settings.homeCards.append(HomeEntry(card: card))
                            editing.adding = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: card.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.12)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(card.title)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(card.isOn(settings) ? "Add to Home" : "Off · \(card.featureHint)")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(card.summary)
                    .accessibilityLabel("Add \(card.title)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
