import AppKit
import SwiftUI

/// Quick drops waiting under the collapsed notch. Drag the pile to take every file at once, or rest
/// the pointer on it to fan the files out and take one. A file dropped into another app leaves the
/// shelf (hold ⌥ to keep it); a click opens the shelf.
struct ShelfStackRow: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var shelf: ShelfStore

    /// Files shown one by one when fanned out; the rest are counted.
    private static let fanLimit = 4

    var body: some View {
        let items = shelf.stack
        let fanned = viewModel.stackHovered && items.count > 1
        HStack(spacing: 8) {
            // The pile: always there, always drags everything.
            HStack(spacing: 7) {
                StackPile(items: Array(items.prefix(3)))
                if !fanned {
                    Text(items.count == 1 ? items[0].name : "\(items.count) files")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .transition(.opacity)
                }
            }
            .overlay(FileDragSource(items: items, onClick: openShelf))
            .help(items.count == 1 ? "Drag into any app · ⌥ keeps it on the shelf" : "Drag all \(items.count) files · ⌥ keeps them on the shelf")

            if fanned {
                Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 14)
                ForEach(items.prefix(Self.fanLimit)) { item in
                    StackThumb(item: item, size: 20)
                        .overlay(FileDragSource(items: [item], onClick: openShelf))
                        .help(item.name)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                if items.count > Self.fanLimit {
                    Text("+\(items.count - Self.fanLimit)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: fanned)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: items.map(\.id))
    }

    private func openShelf() {
        UserDefaults.standard.set(ShelfPane.shelf.rawValue, forKey: "shelf.pane")
        viewModel.open(tab: .shelf, takeKeyboard: false)
    }
}

/// Up to three thumbnails piled up with a slight fan, like a stack of papers.
private struct StackPile: View {
    let items: [ShelfItem]

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated().reversed()), id: \.element.id) { i, item in
                StackThumb(item: item, size: 20)
                    .rotationEffect(.degrees([0, -8, 8][i]))
                    .offset(x: CGFloat(i) * 3)
            }
        }
        .frame(width: 28, height: 24)
    }
}

private struct StackThumb: View {
    @ObservedObject var item: ShelfItem
    let size: CGFloat

    var body: some View {
        Group {
            if item.isVisual {
                // A photo-like preview: cropped square, with a hairline so a white page still has an edge.
                Image(nsImage: item.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size - 2, height: size - 2)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            } else {
                Image(nsImage: item.icon).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
    }
}

/// An AppKit drag source over a SwiftUI view. SwiftUI's `onDrag` can't say whether the drop
/// landed; this can, so files dropped into another app leave the shelf.
struct FileDragSource: NSViewRepresentable {
    let items: [ShelfItem]
    let onClick: () -> Void
    var onClickEvent: ((NSEvent) -> Void)? = nil
    var removesDelivered = true

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.items = items
        view.onClick = onClick
        view.onClickEvent = onClickEvent
        view.removesDelivered = removesDelivered
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var items: [ShelfItem] = []
    var onClick: () -> Void = {}
    /// A click that knows its modifiers and count (the shelf's tiles: pick, ⌘/⇧ to pick more, double-click to open).
    var onClickEvent: ((NSEvent) -> Void)?
    /// Delivered files leave the shelf (the stack's quick drops); the shelf's own tiles stay put.
    var removesDelivered = true
    private var mouseDown: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Right-clicks go through to the SwiftUI view underneath, for its context menu.
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .rightMouseDown, .rightMouseUp, .otherMouseDown: return nil
        case .leftMouseDown where NSApp.currentEvent?.modifierFlags.contains(.control) == true: return nil
        default: return super.hitTest(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDown = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDown else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 9 else { return }
        mouseDown = nil

        let origin = convert(down.locationInWindow, from: nil)
        let dragItems = items.enumerated().map { i, item -> NSDraggingItem in
            // A saved web link drops as the link itself (into a browser, Messages, a doc…).
            let writer: NSPasteboardWriting = ShelfStore.webLink(in: item.url).map { $0 as NSURL }
                ?? MainActor.assumeIsolated { ShelfNames.outgoing(item.url) } as NSURL
            let dragItem = NSDraggingItem(pasteboardWriter: writer)
            let offset = CGFloat(min(i, 4)) * 4
            dragItem.setDraggingFrame(NSRect(x: origin.x - 24 + offset, y: origin.y - 24 - offset, width: 48, height: 48),
                                      contents: item.thumbnail)
            return dragItem
        }
        guard !dragItems.isEmpty else { return }
        let session = beginDraggingSession(with: dragItems, event: down, source: self)
        session.draggingFormation = .stack
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDown != nil else { return }
        mouseDown = nil
        if let onClickEvent { onClickEvent(event) } else { onClick() }
    }

    // Copy only: dropping into a Finder folder must never move the original file away.
    // Inside the app (back onto the notch) there's nothing to do.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Delivered: it's done its job, so it leaves the shelf, unless ⌥ is held to keep it.
        guard removesDelivered, operation != [], !NSEvent.modifierFlags.contains(.option) else { return }
        MainActor.assumeIsolated {
            let gone = items.filter { !$0.pinned }
            guard !gone.isEmpty else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { ShelfStore.shared.remove(gone) }
            Haptics.level()
        }
    }
}
