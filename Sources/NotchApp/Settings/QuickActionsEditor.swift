import SwiftUI

/// Settings › Controls › Quick actions: the Controls grid as the notch draws it, edited in place
/// (drag to rearrange, drag off the panel to remove, click for details), and a gallery to add from
/// by clicking or dragging onto the grid. Built like the Live Activities editor: plain drag
/// gestures and a hand-made layout, so tiles slide aside live instead of jumping on drop.

/// State shared by the grid, the gallery and the pane: a gallery tile on its way to the grid, and
/// the last removal (for undo). `location` is in global (window) coordinates.
@MainActor
final class QuickActionsEditor: ObservableObject {
    @Published var incoming: ControlAction?
    @Published var location: CGPoint = .zero
    @Published var incomingTarget: Int?

    struct Removal: Equatable {
        let id = UUID()
        let message: String
        let tiles: [ControlAction]
    }
    @Published private(set) var lastRemoval: Removal?

    func remove(_ actions: [ControlAction]) {
        let store = ControlTiles.shared
        let removing = store.tiles.filter { actions.contains($0) }
        guard !removing.isEmpty else { return }
        let removal = Removal(message: removing.count == 1 ? "Removed \(removing[0].title)" : "Removed \(removing.count) actions",
                              tiles: store.tiles)
        lastRemoval = removal
        removing.forEach { store.remove($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.lastRemoval == removal { self?.lastRemoval = nil }
        }
    }

    func undo() {
        guard let removal = lastRemoval else { return }
        lastRemoval = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { ControlTiles.shared.tiles = removal.tiles }
    }

    func toggle(_ action: ControlAction) {
        let store = ControlTiles.shared
        if store.tiles.contains(action) { remove([action]) } else { store.add(action) }
    }
}

struct QuickActionsSection: View {
    @ObservedObject var editor: QuickActionsEditor
    @ObservedObject private var tiles = ControlTiles.shared

    var body: some View {
        Section {
            QuickActionStage(editor: editor)
                .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
        } header: {
            HStack {
                Text("Quick actions")
                Spacer()
                Text("\(tiles.tiles.count) of \(ControlTiles.limit)").foregroundStyle(.secondary)
                Button("Restore Defaults") { tiles.reset() }.buttonStyle(.borderless).font(.caption)
            }
        } footer: {
            FooterText("Up to eight show as a 4 × 2 grid; more make it 6 × 2.")
        }
        Section {
            QuickActionGallery(editor: editor)
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        } header: {
            Text("Add quick actions")
        } footer: {
            FooterText(tiles.isFull ? "The grid is full. Remove one to add another."
                       : "Click to add or remove, or drag onto the grid.")
        }
    }
}

// MARK: - The grid

private struct QuickActionStage: View {
    @ObservedObject var editor: QuickActionsEditor
    @ObservedObject private var store = ControlTiles.shared
    @State private var width: CGFloat = 520
    @State private var frame: CGRect = .zero
    @State private var drag: Drag?
    @State private var selected: ControlAction?
    @State private var hovered: ControlAction?

    private struct Drag {
        var action: ControlAction
        var location: CGPoint
        var grab: CGSize
        /// Where it would land; nil while it's off the panel (and would be removed).
        var target: Int?
    }

    private let pad: CGFloat = 14
    private let gap: CGFloat = 6
    private let tileHeight: CGFloat = 66
    private let rows = 2
    private let footer: CGFloat = 40

    private var panelHeight: CGFloat { pad * 2 + CGFloat(rows) * tileHeight + CGFloat(rows - 1) * gap }
    private var panel: CGRect { CGRect(x: 0, y: 0, width: width, height: panelHeight) }

    /// The order being shown: a dragged tile at its target, or taken out while it's off the panel.
    private func order(for drag: Drag?) -> [ControlAction] {
        var tiles = store.tiles
        guard let drag else { return tiles }
        tiles.removeAll { $0 == drag.action }
        if let target = drag.target { tiles.insert(drag.action, at: min(target, tiles.count)) }
        return tiles
    }

    private var activeDrag: Drag? {
        if let drag { return drag }
        guard let action = editor.incoming, let target = editor.incomingTarget else { return nil }
        return Drag(action: action, location: .zero, grab: .zero, target: target)
    }

    private func columns(_ count: Int) -> Int { count > 8 ? 6 : 4 }
    private func tileWidth(_ columns: Int) -> CGFloat { (width - pad * 2 - CGFloat(columns - 1) * gap) / CGFloat(columns) }

    private func center(of index: Int, columns: Int) -> CGPoint {
        let w = tileWidth(columns)
        let col = index % columns, row = index / columns
        return CGPoint(x: pad + CGFloat(col) * (w + gap) + w / 2, y: pad + CGFloat(row) * (tileHeight + gap) + tileHeight / 2)
    }

    /// The slot under a point, counting the tiles as they'd be with the dragged one included.
    private func slot(at point: CGPoint, count: Int) -> Int? {
        guard panel.insetBy(dx: -12, dy: -12).contains(point) else { return nil }
        let cols = columns(count)
        let w = tileWidth(cols)
        let col = min(max(Int((point.x - pad + gap / 2) / (w + gap)), 0), cols - 1)
        let row = min(max(Int((point.y - pad + gap / 2) / (tileHeight + gap)), 0), rows - 1)
        return min(row * cols + col, count - 1)
    }

    var body: some View {
        let drag = activeDrag
        let shown = order(for: drag)
        let cols = columns(shown.count)
        ZStack(alignment: .topLeading) {
            // The panel, as the notch draws the Controls grid.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(editor.incomingTarget != nil ? Color.accentColor : .white.opacity(0.08),
                                  lineWidth: editor.incomingTarget != nil ? 2 : 1))
                .frame(width: width, height: panelHeight)
            if store.tiles.isEmpty && drag == nil {
                VStack(spacing: 4) {
                    Text("No quick actions").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    Text("Add some below.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                }
                .position(x: width / 2, y: panelHeight / 2)
            }
            // The gap a dragged tile will drop into.
            if let drag, drag.target != nil, let i = shown.firstIndex(of: drag.action) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .frame(width: tileWidth(cols) - 4, height: tileHeight - 4)
                    .position(center(of: i, columns: cols))
            }
            // Every tile stays in the view tree while dragged (hidden), or its gesture would end.
            ForEach(store.tiles) { action in
                let index = shown.firstIndex(of: action) ?? store.tiles.firstIndex(of: action) ?? 0
                tile(action, at: center(of: index, columns: shown.firstIndex(of: action) == nil ? columns(store.tiles.count) : cols),
                     width: tileWidth(shown.firstIndex(of: action) == nil ? columns(store.tiles.count) : cols))
                    .opacity(drag?.action == action ? 0 : 1)
            }
            if let drag = self.drag {
                QuickActionDragTile(action: drag.action, landing: drag.target != nil)
                    .position(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
                    .allowsHitTesting(false)
                    .transaction { $0.animation = nil }
            }
            footerStrip
                .frame(width: width, height: footer)
                .offset(y: panelHeight)
        }
        .frame(height: panelHeight + footer, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(name: "quickStage")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0; width = max($0.width, 240) }
        .onChange(of: editor.location) { _, location in
            guard let action = editor.incoming else { return }
            let point = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
            let count = store.tiles.contains(action) ? store.tiles.count : store.tiles.count + 1
            let target = store.tiles.contains(action) || !store.isFull ? slot(at: point, count: count) : nil
            if editor.incomingTarget != target { editor.incomingTarget = target }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: store.tiles)
        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: drag?.target)
        .animation(.easeOut(duration: 0.15), value: self.drag == nil)
        .animation(.easeOut(duration: 0.2), value: editor.lastRemoval)
    }

    private func tile(_ action: ControlAction, at point: CGPoint, width: CGFloat) -> some View {
        VStack(spacing: 6) {
            Image(systemName: action.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white.opacity(hovered == action ? 0.18 : 0.11)))
            Text(action.title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: width, height: tileHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(selected == action ? 0.12 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected == action ? Color.accentColor : .clear, lineWidth: 1.5))
        .opacity(action.isAvailable ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside ? action : (hovered == action ? nil : hovered)
            guard drag == nil else { return }
            (inside ? NSCursor.openHand : NSCursor.arrow).set()
        }
        .onTapGesture { selected = action }
        .gesture(dragGesture(action, from: point))
        .popover(isPresented: Binding(get: { selected == action }, set: { if !$0 { selected = nil } }), arrowEdge: .bottom) {
            QuickActionDetails(action: action) {
                selected = nil
                editor.remove([action])
            }
        }
        .help(action.isAvailable ? action.title : "\(action.title): \(action.unavailableNote)")
        .position(point)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private func dragGesture(_ action: ControlAction, from center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("quickStage"))
            .onChanged { value in
                if drag == nil {
                    selected = nil
                    NSCursor.closedHand.set()
                    drag = Drag(action: action, location: value.startLocation,
                                grab: CGSize(width: value.startLocation.x - center.x, height: value.startLocation.y - center.y),
                                target: store.tiles.firstIndex(of: action))
                }
                drag?.location = value.location
                let point = CGPoint(x: value.location.x - (drag?.grab.width ?? 0), y: value.location.y - (drag?.grab.height ?? 0))
                drag?.target = slot(at: point, count: store.tiles.count)
            }
            .onEnded { _ in
                NSCursor.arrow.set()
                guard let drag else { return }
                if let target = drag.target { store.place(action, at: target) } else { editor.remove([action]) }
                self.drag = nil
            }
    }

    @ViewBuilder private var footerStrip: some View {
        ZStack {
            if let drag, drag.target == nil {
                Label("Release to remove", systemImage: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    .transition(.opacity.combined(with: .offset(y: 6)))
            } else if drag != nil {
                Text("Drag off the panel to remove")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            } else if editor.incoming != nil {
                Text(editor.incomingTarget == nil
                     ? (store.isFull && !store.tiles.contains(editor.incoming!) ? "The grid is full" : "Drop on the grid to add")
                     : "Release to add")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            } else if let removal = editor.lastRemoval {
                HStack(spacing: 10) {
                    Text(removal.message).foregroundStyle(.primary.opacity(0.85))
                    Button("Undo") { editor.undo() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .keyboardShortcut("z", modifiers: .command)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .id(removal.id)
                .transition(.opacity.combined(with: .offset(y: 6)))
            } else if !store.tiles.isEmpty {
                Text("Drag to rearrange  ·  Click for details  ·  Drag off to remove")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// A tile lifted off the grid or the gallery, under the pointer.
struct QuickActionDragTile: View {
    let action: ControlAction
    let landing: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: action.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white.opacity(0.16)))
            Text(action.title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .frame(width: 84, height: 66)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .scaleEffect(landing ? 1.06 : 0.92)
        .opacity(landing ? 1 : 0.8)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: landing)
    }
}

/// A tile's details, in a popover from the grid.
private struct QuickActionDetails: View {
    let action: ControlAction
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                QuickActionIcon(action: action, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.system(size: 13, weight: .semibold))
                    Text(action.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !action.isAvailable {
                        Label(action.unavailableNote, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
            Button(role: .destructive, action: remove) {
                Text("Remove from Controls").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.delete, modifiers: [])
        }
        .padding(16)
        .frame(width: 280)
    }
}

// MARK: - The gallery

private struct QuickActionGallery: View {
    @ObservedObject var editor: QuickActionsEditor
    @ObservedObject private var store = ControlTiles.shared

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
            ForEach(ControlAction.allCases) { action in
                QuickActionGalleryTile(action: action, added: store.tiles.contains(action), full: store.isFull, editor: editor)
            }
        }
    }
}

private struct QuickActionGalleryTile: View {
    let action: ControlAction
    let added: Bool
    let full: Bool
    @ObservedObject var editor: QuickActionsEditor
    @ObservedObject private var store = ControlTiles.shared
    @State private var hovering = false

    private var blocked: Bool { !added && full }
    private var dragged: Bool { editor.incoming == action }

    var body: some View {
        VStack(spacing: 8) {
            QuickActionIcon(action: action, size: 32)
            Text(action.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(added ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(added ? Color.accentColor.opacity(0.12) : Color.primary.opacity(hovering && !blocked ? 0.07 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(added ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.06), lineWidth: added ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                .font(.system(size: 14))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, added ? Color.accentColor : Color.secondary.opacity(0.6))
                .opacity(added || (hovering && !blocked) ? 1 : 0)
                .padding(6)
        }
        .overlay(alignment: .topLeading) {
            if !action.isAvailable {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(6)
            }
        }
        .opacity(dragged ? 0.4 : blocked ? 0.45 : 1)
        .scaleEffect(hovering && !blocked && !dragged ? 1.02 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { inside in
            hovering = inside
            guard editor.incoming == nil else { return }
            (inside ? (blocked ? NSCursor.operationNotAllowed : NSCursor.openHand) : NSCursor.arrow).set()
        }
        .onTapGesture { if !blocked { editor.toggle(action) } }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    guard !blocked else { return }
                    if editor.incoming == nil {
                        editor.incoming = action
                        NSCursor.closedHand.set()
                    }
                    editor.location = value.location
                }
                .onEnded { _ in
                    if let target = editor.incomingTarget { store.place(action, at: target) }
                    editor.incoming = nil
                    editor.incomingTarget = nil
                    NSCursor.arrow.set()
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(added ? "In Controls" : "Not added")
        .accessibilityAction { if !blocked { editor.toggle(action) } }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: added)
        .help(blocked ? "The grid is full (\(ControlTiles.limit) at most). Remove one first."
              : action.isAvailable ? action.detail : "\(action.detail) \(action.unavailableNote)")
    }
}

private struct QuickActionIcon: View {
    let action: ControlAction
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: action.icon)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [action.tint.opacity(0.95), action.tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            )
    }
}

extension ControlAction {
    /// Why an action is hidden in the notch right now, if it is.
    var unavailableNote: String {
        switch self {
        case .cleaner: "Shows once the Tools tab is on."
        case .clipboard: "Shows once Clipboard history is on."
        case .nightShift: "This Mac doesn't support Night Shift."
        case .saveVideo: "Needs yt-dlp (brew install yt-dlp)."
        default: "Hidden until its feature is turned on."
        }
    }
}
