import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Quick drops waiting under the collapsed notch. Drag the pile to take every file at once, or rest
/// the pointer on it to fan the files out and take one, or all of them as a zip. A file dropped
/// into another app leaves the shelf (hold ⌥ to keep it); a click opens the shelf.
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
                // All of them as one zip, made where it's dropped.
                Image(systemName: "doc.zipper")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 22, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.12)))
                    .overlay(FileDragSource(items: items, onClick: openShelf, asZip: true))
                    .help("Drag all \(items.count) files as one zip · ⌥ keeps them on the shelf")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
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

/// Up to three thumbnails piled up with a slight fan, like a stack of papers (under the notch, and
/// bigger in the shake-summoned tray).
struct StackPile: View {
    let items: [ShelfItem]
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated().reversed()), id: \.element.id) { i, item in
                StackThumb(item: item, size: size)
                    .rotationEffect(.degrees([0, -8, 8][i]))
                    .offset(x: CGFloat(i) * 3 * size / 20)
            }
        }
        .frame(width: size * 1.4, height: size * 1.2)
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
    /// Leaves as one zip, made where it's dropped, instead of the files themselves.
    var asZip = false

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
        view.asZip = asZip
    }
}

/// The zip a drag hands over: a promise, made in the folder (or app) it's dropped into, under the
/// files' shelf names.
final class ZipPromise: NSObject, NSFilePromiseProviderDelegate {
    let files: [URL]
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    init(files: [URL]) { self.files = files }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        ShelfStore.zipName(for: files)
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(ShelfStore.makeZip(files, to: url) ? nil : CocoaError(.fileWriteUnknown))
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
}

final class DragSourceView: NSView, NSDraggingSource {
    var items: [ShelfItem] = []
    var onClick: () -> Void = {}
    /// A click that knows its modifiers and count (the shelf's tiles: pick, ⌘/⇧ to pick more, double-click to open).
    var onClickEvent: ((NSEvent) -> Void)?
    /// Delivered files leave the shelf (the stack's quick drops); the shelf's own tiles stay put.
    var removesDelivered = true
    var asZip = false
    private var mouseDown: NSEvent?
    private var promise: ZipPromise?

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
        if asZip {
            let files = MainActor.assumeIsolated { items.filter { $0.url.isFileURL && ShelfStore.webLink(in: $0.url) == nil }.map { ShelfNames.outgoing($0.url) } }
            guard !files.isEmpty else { return }
            let promise = ZipPromise(files: files)
            self.promise = promise
            let item = NSDraggingItem(pasteboardWriter: NSFilePromiseProvider(fileType: UTType.zip.identifier, delegate: promise))
            item.setDraggingFrame(NSRect(x: origin.x - 24, y: origin.y - 24, width: 48, height: 48),
                                  contents: NSWorkspace.shared.icon(for: .zip))
            beginDraggingSession(with: [item], event: down, source: self).animatesToStartingPositionsOnCancelOrFail = true
            return
        }
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

    /// Where each file was when the drag began, by a bookmark that follows it if Finder moves it.
    private var bookmarks: [UUID: Data] = [:]

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        bookmarks = Dictionary(uniqueKeysWithValues: items.compactMap { item in (try? item.url.bookmarkData()).map { (item.id, $0) } })
    }

    // A copy unless asked otherwise, so a drop into a Finder folder never takes the original away by
    // surprise: ⌘ moves it (Finder's own key), or "Like Finder" lets Finder decide. Files leaving
    // under a made-up name are copies already, and links have nothing to move. Inside the app (back
    // onto the notch) there's nothing to do.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard context == .outsideApplication else { return [] }
        if asZip { return .copy }
        let movable = MainActor.assumeIsolated {
            items.allSatisfy { $0.url.isFileURL && ShelfStore.webLink(in: $0.url) == nil && !ShelfNames.isOn(for: $0.url) }
                && (AppSettings.shared.shelfDragOut == .finder || NSEvent.modifierFlags.contains(.command))
        }
        return movable ? [.copy, .move, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation != [] else { return }
        let keep = NSEvent.modifierFlags.contains(.option)
        let items = items, bookmarks = bookmarks
        MainActor.assumeIsolated {
            // Delivered: a quick drop has done its job, so it leaves the shelf, unless ⌥ is held to keep it.
            if removesDelivered, !keep {
                let gone = items.filter { !$0.pinned }
                if !gone.isEmpty {
                    withAnimation(Motion.pane.animation) { ShelfStore.shared.remove(gone) }
                    Haptics.level()
                }
            }
            guard !asZip, operation.contains(.move) || operation.contains(.generic) else { return }
            // Finder moves the files in its own time: then the shelf follows each one to where it went.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let moved = items.filter { item in ShelfStore.shared.items.contains { $0.id == item.id } && !FileManager.default.fileExists(atPath: item.url.path) }
                guard !moved.isEmpty else { return }
                ShelfStore.shared.follow(moved.map { item in
                    var stale = false
                    let url = bookmarks[item.id].flatMap { try? URL(resolvingBookmarkData: $0, bookmarkDataIsStale: &stale) }
                    return (item, url)
                })
            }
        }
    }
}
