import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

enum ShelfPane: String {
    case shelf, downloads, clipboard

    @MainActor static var options: [(value: ShelfPane, title: String)] {
        let s = AppSettings.shared
        return [(.shelf, "Shelf")] + (s.downloadsEnabled ? [(.downloads, "Downloads")] : [])
            + (s.clipboardHistory ? [(.clipboard, "Clipboard")] : [])
    }
}

struct ShelfView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var shelf: ShelfStore
    @EnvironmentObject private var downloads: DownloadsStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var taildrop: TaildropService
    @EnvironmentObject private var clipboard: ClipboardHistory
    @EnvironmentObject private var videos: VideoDownloader
    @EnvironmentObject private var converter: MediaConverter
    @AppStorage("shelf.pane") private var pane: ShelfPane = .shelf
    @State private var clipQuery = ""
    @State private var clipKind: ClipboardHistory.Clip.Kind?
    @ObservedObject private var drag = DragActivity.shared

    private var showsTaildrop: Bool { settings.taildropZone && TaildropService.cli != nil }

    private var showingDownloads: Bool { settings.downloadsEnabled && pane == .downloads }
    private var showingClipboard: Bool { settings.clipboardHistory && pane == .clipboard }
    private var hasPanes: Bool { settings.downloadsEnabled || settings.clipboardHistory }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if !taildrop.pending.isEmpty {
                    DevicePicker(viewModel: viewModel)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if let urls = shelf.convertPicker {
                    ConvertPicker(urls: urls)
                        .onDisappear { shelf.convertPicker = nil } // closing the notch puts it away
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if shelf.items.isEmpty && !hasPanes {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        header.notchHeaderRow()
                        if showingClipboard {
                            ClipboardStrip(viewModel: viewModel, query: $clipQuery, kind: $clipKind)
                        } else if showingDownloads {
                            if !videos.jobs.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(videos.jobs.prefix(3)) { VideoJobTile(job: $0) }
                                    if !downloads.items.isEmpty {
                                        TileStrip(items: downloads.items, regionID: "downloads", viewModel: viewModel) {
                                            ShelfTile(item: $0, kind: .download)
                                        }
                                    } else {
                                        Spacer(minLength: 0)
                                    }
                                }
                            } else if downloads.items.isEmpty {
                                placeholder(icon: "arrow.down.circle", text: "No downloads yet")
                            } else {
                                TileStrip(items: downloads.items, regionID: "downloads", viewModel: viewModel) {
                                    ShelfTile(item: $0, kind: .download)
                                }
                            }
                        } else if shelf.items.isEmpty && converter.jobs.isEmpty {
                            emptyState
                        } else {
                            HStack(spacing: 6) {
                                ForEach(converter.activeBatches.prefix(2)) { ConvertJobTile(batch: $0) }
                                // Quick drops first (newest first), then what's pinned to stay.
                                TileStrip(items: shelf.shown, regionID: "shelf", viewModel: viewModel) {
                                    ShelfTile(item: $0, kind: .shelf)
                                }
                                // A click between the files lets go of the picked ones.
                                .background(Color.clear.contentShape(Rectangle()).onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { shelf.selection = [] }
                                })
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: taildrop.pending.isEmpty)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: shelf.convertPicker)

            // Beside the clipboard they're only drop targets, so they wait for something to be dragged.
            if (settings.airDropZone || showsTaildrop) && (!showingClipboard || drag.active) {
                VStack(spacing: 8) {
                    if settings.airDropZone { AirDropZone(compact: showsTaildrop) }
                    if showsTaildrop { TaildropZone(compact: settings.airDropZone) }
                }
                .frame(width: 104)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showingClipboard && !drag.active)
    }

    private var header: some View {
        HStack {
            if hasPanes {
                PaneSwitcher(selection: $pane, options: ShelfPane.options)
            } else {
                Text("Shelf")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if showingClipboard, !clipboard.selection.isEmpty {
                let picked = clipboard.clips.filter { clipboard.selection.contains($0.id) }
                HStack(spacing: 10) {
                    Text("\(picked.count) selected")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    headerButton("Paste") { clipboard.pasteTogether(picked) }
                    headerButton("Copy") { clipboard.copyTogether(picked) }
                    headerButton("Save to Shelf") { picked.forEach(clipboard.saveToShelf) }
                    headerButton("Remove") { clipboard.remove(picked) }
                    headerButton("Done") { withAnimation(.easeOut(duration: 0.12)) { clipboard.selection = [] } }
                }
            } else if showingClipboard {
                if !clipboard.clips.isEmpty { clipboardFilters }
                if clipboard.clips.contains(where: { !$0.pinned }) {
                    Button("Clear") { clipboard.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .help("Clears everything except pinned items")
                }
            } else if showingDownloads {
                if videos.jobs.contains(where: { !$0.isActive }) {
                    Button("Clear Finished") { videos.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Button("Open Folder") { NSWorkspace.shared.open(downloads.folder) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else if !shelf.selection.isEmpty {
                selectionBar
            } else if !shelf.items.isEmpty {
                // Like the clipboard: Clear keeps pinned files; with only pinned ones left it clears those.
                let quick = shelf.stack
                Button(quick.isEmpty ? "Clear All" : "Clear") {
                    withAnimation(.spring(response: 0.3)) { quick.isEmpty ? shelf.clear() : shelf.remove(quick) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .help(quick.isEmpty ? "Removes everything from the shelf" : "Clears everything except pinned files")
            }
        }
    }

    /// Find a copy: a search box and the kinds of thing copied.
    private var clipboardFilters: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                TextField("", text: $clipQuery, prompt: Text("Search").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 92)
                if !clipQuery.isEmpty {
                    Button { clipQuery = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .notchSurface(Capsule())
            HStack(spacing: 1) {
                ForEach([(nil, "square.grid.2x2", "Everything"), (ClipboardHistory.Clip.Kind.text, "text.alignleft", "Text"),
                         (.link, "link", "Links"), (.image, "photo", "Images"), (.files, "doc", "Files")], id: \.1) { kind, icon, help in
                    Button { withAnimation(.easeOut(duration: 0.15)) { clipKind = kind } } label: {
                        Image(systemName: icon)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(clipKind == kind ? 0.95 : 0.4))
                            .frame(width: 22, height: 18)
                            .background(Capsule().fill(.white.opacity(clipKind == kind ? 0.16 : 0)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(help)
                }
            }
        }
    }

    /// With files picked: what can be done to all of them at once.
    private var selectionBar: some View {
        let picked = shelf.selectedItems
        let urls = picked.map(\.url)
        let conversions = MediaConverter.operations(for: urls)
        return HStack(spacing: 10) {
            Text("\(picked.count) selected")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            if !conversions.isEmpty {
                Menu {
                    ForEach(conversions.filter { !$0.isEdit }) { op in Button(op.title) { converter.convert(urls, op) } }
                    Divider()
                    ForEach(conversions.filter(\.isEdit)) { op in Button(op.title) { converter.convert(urls, op) } }
                } label: {
                    Label("Convert", systemImage: "wand.and.stars")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
            }
            headerButton("Zip") { shelf.compress(picked) }
            headerButton("AirDrop") { ShelfStore.airDrop(urls) }
            headerButton("Remove") { withAnimation(.spring(response: 0.3)) { shelf.remove(picked) } }
            headerButton("Done") { withAnimation(.easeOut(duration: 0.12)) { shelf.selection = [] } }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
    }

    private func headerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.45))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.03)))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 22, weight: .medium))
                    Text("Drop files here")
                        .font(.system(size: 12, weight: .medium))
                    if settings.screenshotCatcher {
                        Text("New screenshots land here too")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .foregroundStyle(.white.opacity(0.6))
            }
    }
}

/// Horizontally scrolling row of file tiles; two-finger swipes scroll it when it overflows.
private struct TileStrip<Tile: View>: View {
    let items: [ShelfItem]
    let regionID: String
    @ObservedObject var viewModel: NotchViewModel
    @ViewBuilder let tile: (ShelfItem) -> Tile
    @State private var overflows = false

    var body: some View {
        GeometryReader { outer in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        tile(item)
                            .scrollEdgeFade()
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: items.map(\.id))
                .background(GeometryReader { inner in
                    Color.clear
                        .onAppear { overflows = inner.size.width > outer.size.width + 1 }
                        .onChange(of: inner.size.width > outer.size.width + 1) { _, o in overflows = o }
                })
            }

        }
        .horizontalScrollRegion(regionID, in: viewModel, active: overflows)
    }
}

private struct ShelfTile: View {
    enum Kind { case shelf, download }

    @ObservedObject var item: ShelfItem
    let kind: Kind
    @EnvironmentObject private var shelf: ShelfStore
    @State private var hovering = false

    private var selected: Bool { kind == .shelf && shelf.selection.contains(item.id) }
    /// What a drag or a menu acts on: everything picked, when this is one of them.
    private var targets: [ShelfItem] { kind == .shelf ? shelf.targets(for: item) : [item] }

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: item.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(selected ? 1 : 0.8))
                .frame(width: 72, height: 26, alignment: .top)
        }
        .padding(6)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            if selected {
                shape.fill(Color.accentColor.opacity(0.3))
                    .overlay(shape.strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1))
            } else {
                shape.fill(.white.opacity(hovering ? 0.1 : 0))
            }
        }
        .overlay(alignment: .topLeading) {
            if kind == .shelf && item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .rotationEffect(.degrees(45))
                    .shadow(color: .black, radius: 1.5)
                    .padding(5)
                    .help("Pinned: stays on the shelf")
            }
        }
        // Clicks and drags in AppKit: a drag carries every picked file, which SwiftUI's can't.
        .overlay {
            FileDragSource(items: targets, onClick: {}, onClickEvent: { event in
                if event.clickCount >= 2 {
                    NSWorkspace.shared.open(item.url)
                } else if kind == .shelf {
                    withAnimation(.easeOut(duration: 0.12)) { shelf.click(item, modifiers: event.modifierFlags) }
                }
            }, removesDelivered: false)
        }
        .overlay(alignment: .topTrailing) {
            if hovering && kind == .shelf && shelf.selection.count < 2 {
                Button { withAnimation(.spring(response: 0.3)) { ShelfStore.shared.remove(item) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.3))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu { ShelfFileMenu(item: item, targets: targets, kind: kind) }
        .help(item.url.path)
    }
}

/// Right-click on a file on the shelf (or in Downloads): for every picked file at once.
private struct ShelfFileMenu: View {
    let item: ShelfItem
    let targets: [ShelfItem]
    let kind: ShelfTile.Kind

    private var urls: [URL] { targets.map(\.url) }
    private var many: Bool { targets.count > 1 }

    /// The selection's size, worked out once per selection (the menu is rebuilt on every redraw).
    @MainActor private static var sizeCache: (key: [URL], bytes: Int64)?
    @MainActor static func size(of urls: [URL]) -> Int64 {
        if let hit = sizeCache, hit.key == urls { return hit.bytes }
        let bytes = urls.reduce(Int64(0)) { $0 + Cleaner.allocatedSize($1) }
        sizeCache = (urls, bytes)
        return bytes
    }

    var body: some View {
        if many {
            Text("\(targets.count) files · \(formatBytes(Self.size(of: urls)))")
        }
        MenuItem(many ? "Open All" : "Open", "arrow.up.forward.square") { urls.forEach { NSWorkspace.shared.open($0) } }
        OpenWithMenu(urls: urls)
        MenuItem("Quick Look", "eye") { QuickLookPreview.shared.show(urls) }
        MenuItem("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        Divider()
        MenuItem("Copy", "doc.on.doc") { ShelfStore.copy(urls) }
        Menu {
            MenuItem(many ? "Paths" : "Path", "point.topleft.down.to.point.bottomright.curvepath") { ShelfStore.copyPaths(urls) }
            MenuItem(many ? "Names" : "Name", "textformat") { ShelfStore.copyText(urls.map(\.lastPathComponent).joined(separator: "\n")) }
            if !many, MediaConverter.kind(of: item.url) == .image {
                MenuItem("Text in Image", "text.viewfinder") { ShelfStore.copyTextInImage(item.url) }
            }
        } label: {
            Label("Copy As", systemImage: "doc.on.clipboard")
        }
        Divider()
        ShareLink(items: urls) { Label("Share…", systemImage: "square.and.arrow.up") }
        MenuItem("AirDrop", "dot.radiowaves.left.and.right") { ShelfStore.airDrop(urls) }
        if AppSettings.shared.taildropZone, TaildropService.cli != nil {
            MenuItem("Taildrop…", "paperplane") { TaildropService.shared.offer(urls) }
        }
        Divider()
        let conversions = MediaConverter.operations(for: urls)
        if !conversions.isEmpty {
            Menu {
                ForEach(conversions.filter { !$0.isEdit }) { op in
                    MenuItem(op.title, op.symbol) { MediaConverter.shared.convert(urls, op) }
                }
                Divider()
                ForEach(conversions.filter(\.isEdit)) { op in
                    MenuItem(op.title, op.symbol) { MediaConverter.shared.convert(urls, op) }
                }
            } label: {
                Label(many ? "Convert \(targets.count) Files" : "Convert", systemImage: "wand.and.stars")
            }
        }
        if targets.allSatisfy({ MediaConverter.kind(of: $0.url) == .image }), targets.count <= 10 {
            MenuItem("Remove Background", "person.crop.rectangle") { Cutout.run(urls) }
        }
        MenuItem(many ? "Compress \(targets.count) Files" : "Compress", "doc.zipper") { ShelfStore.shared.compress(targets) }
        MenuItem(many ? "Duplicate All" : "Duplicate", "plus.square.on.square") { ShelfStore.shared.duplicate(targets) }
        Menu {
            let fm = FileManager.default
            ForEach([(FileManager.SearchPathDirectory.desktopDirectory, "menubar.dock.rectangle"), (.documentDirectory, "doc"),
                     (.downloadsDirectory, "arrow.down.circle")], id: \.1) { dir, icon in
                let folder = fm.urls(for: dir, in: .userDomainMask)[0]
                MenuItem(folder.lastPathComponent, icon) { ShelfStore.shared.move(targets, to: folder) }
            }
            Divider()
            MenuItem("Choose Folder…", "folder.badge.plus") { ShelfStore.shared.chooseFolderAndMove(targets) }
        } label: {
            Label("Move To", systemImage: "folder.badge.gearshape")
        }
        Divider()
        if kind == .shelf {
            // Pinned files stay; unpinned ones are quick drops that leave once used or expired.
            let pin = !targets.allSatisfy(\.pinned)
            MenuItem(pin ? "Pin to Shelf" : "Unpin", pin ? "pin" : "pin.slash") { targets.forEach { ShelfStore.shared.setPinned($0, pin) } }
            MenuItem("Select All", "checkmark.circle") { ShelfStore.shared.selectAll() }
        } else {
            MenuItem("Add to Shelf", "tray.and.arrow.down") { ShelfStore.shared.add(urls) }
        }
        Divider()
        if kind == .shelf {
            MenuItem(many ? "Remove \(targets.count) from Shelf" : "Remove from Shelf", "xmark.circle") {
                withAnimation(.spring(response: 0.3)) { ShelfStore.shared.remove(targets) }
            }
            MenuItem("Move to Trash", "trash", role: .destructive) { ShelfStore.shared.trash(targets) }
        } else {
            MenuItem("Move to Trash", "trash", role: .destructive) { DownloadsStore.shared.moveToTrash(item) }
        }
    }
}

private struct AirDropZone: View {
    var compact = false
    @EnvironmentObject private var shelf: ShelfStore
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(targeted ? Color.blue.opacity(0.35) : .clear)
            .notchSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(targeted ? Color.blue : .clear, lineWidth: 1)
            )
            .overlay {
                VStack(spacing: compact ? 3 : 6) {
                    Image(nsImage: SystemIcons.airDrop)
                        .resizable()
                        .frame(width: compact ? 26 : 34, height: compact ? 26 : 34)
                        .scaleEffect(targeted ? 1.1 : 1)
                    Text("AirDrop")
                        .font(.system(size: compact ? 11 : 12, weight: .medium))
                    if !compact {
                        Text(shelf.items.isEmpty ? "Drop to send" : "Drop, or click\nto send shelf")
                            .font(.system(size: 9))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .scaleEffect(targeted ? 1.04 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { ShelfStore.airDrop(shelf.items.map(\.url)) }
            .onChange(of: targeted) { _, over in if over { Haptics.level() } } // felt while the finger's still down
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                ShelfStore.urls(from: providers) { ShelfStore.airDrop($0) }
                return true
            }
    }
}

enum TaildropPalette {
    static let accent = Color(red: 0.45, green: 0.58, blue: 1.0)
}

/// Drop files to send them to one of your Tailscale devices; click to send what's on the shelf.
private struct TaildropZone: View {
    var compact = false
    @EnvironmentObject private var shelf: ShelfStore
    @EnvironmentObject private var taildrop: TaildropService
    @State private var targeted = false

    var body: some View {
        let accent = TaildropPalette.accent
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(targeted ? accent.opacity(0.35) : .clear)
            .notchSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(targeted ? accent : .clear, lineWidth: 1)
            )
            .overlay {
                if let job = taildrop.sending {
                    VStack(spacing: compact ? 3 : 6) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
                            Circle()
                                .trim(from: 0, to: job.progress ?? 0.08)
                                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: compact ? 18 : 24, height: compact ? 18 : 24)
                        Text(job.device.name)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                        Text(job.progress.map { "\(Int($0 * 100))%" } ?? "Sending…")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                } else {
                    VStack(spacing: compact ? 3 : 6) {
                        TaildropIcon(size: compact ? 26 : 34)
                            .scaleEffect(targeted ? 1.1 : 1)
                        Text("Taildrop")
                            .font(.system(size: compact ? 11 : 12, weight: .medium))
                        if !compact {
                            Text(shelf.items.isEmpty ? "Drop to send" : "Drop, or click\nto send shelf")
                                .font(.system(size: 9))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
            .foregroundStyle(.white.opacity(0.85))
            .scaleEffect(targeted ? 1.04 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture {
                guard taildrop.sending == nil, !shelf.items.isEmpty else { return }
                taildrop.offer(shelf.items.map(\.url))
            }
            .onChange(of: targeted) { _, over in if over { Haptics.level() } } // felt while the finger's still down
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                ShelfStore.urls(from: providers) { TaildropService.shared.offer($0) }
                return true
            }
            .help(shelf.items.isEmpty ? "Drop files to send them to your Tailscale devices" : "Send the shelf with Taildrop")
    }
}

/// Pick which device gets the files.
private struct DevicePicker: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var taildrop: TaildropService

    var body: some View {
        let count = taildrop.pending.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TaildropIcon(size: 16)
                Text(count == 1 ? "Send “\(taildrop.pending[0].lastPathComponent)” to…" : "Send \(count) files to…")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel") { taildrop.cancelPending() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            switch taildrop.status {
            case .notInstalled:
                message("Tailscale isn't installed", button: "Get Tailscale") {
                    NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
                }
            case .stopped:
                message("Tailscale isn't connected", button: "Open Tailscale") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
                }
            case .ready:
                if taildrop.devices.isEmpty {
                    message("No other devices on your tailnet", button: nil) {}
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(taildrop.devices) { device in
                                DeviceChip(device: device) { taildrop.send(to: device) }
                            }
                        }
                    }
                    .horizontalScrollRegion("taildrop.devices", in: viewModel)
                }
            }
        }
        .onAppear { taildrop.refresh() }
    }

    private func message(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            if let button {
                Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeviceChip: View {
    let device: TailDevice
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: device.icon)
                    .font(.system(size: 22, weight: .regular))
                    .frame(height: 26)
                Text(device.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 3) {
                    Circle().fill(device.online ? Color.green : Color.white.opacity(0.3)).frame(width: 5, height: 5)
                    Text(device.online ? "Online" : "Offline")
                }
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 86, height: 84)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering && device.online ? TaildropPalette.accent.opacity(0.25) : .white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering && device.online ? TaildropPalette.accent : .white.opacity(0.08), lineWidth: 1))
            .opacity(device.online ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!device.online)
        .onHover { hovering = $0 }
        .help(device.online ? "Send to \(device.name) (\(device.ip))" : "\(device.name) is offline")
    }
}

/// The real Tailscale app icon, or a paper plane if Tailscale isn't installed.
struct TaildropIcon: View {
    let size: CGFloat

    var body: some View {
        if let icon = SystemIcons.tailscale {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "paperplane.fill")
                .font(.system(size: size * 0.6, weight: .medium))
                .foregroundStyle(TaildropPalette.accent)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Clipboard

/// Recent copies as cards: click one to put it back on the clipboard (the notch closes so you can paste).
/// With the keyboard: ← → move a highlight, typing searches, and the Clipboard keys (↩ paste,
/// ⌘C copy, ⌃X remove, ⇧⌘P pin, ⌘1–⌘9 paste by position; see `ClipboardKey`) act on it.
private struct ClipboardStrip: View {
    @ObservedObject var viewModel: NotchViewModel
    @Binding var query: String
    @Binding var kind: ClipboardHistory.Clip.Kind?
    @EnvironmentObject private var clipboard: ClipboardHistory
    @EnvironmentObject private var settings: AppSettings
    @State private var overflows = false
    /// The clip the keys act on. Opened with a shortcut it starts on the newest; otherwise the
    /// first arrow press puts it there, so the mouse alone never shows a highlight.
    @State private var highlight: UUID?
    /// Modifiers held right now: holding quick paste's shows the numbers on the cards.
    @State private var held: UInt32 = 0
    @State private var monitor: Any?

    private var shown: [ClipboardHistory.Clip] { clipboard.shown(matching: query, kind: kind) }

    var body: some View {
        let shown = shown
        let numbered = ClipboardKey.quickPaste.combo.map { $0.modifiers == held } ?? false
        Group {
            if !clipboard.clips.isEmpty, shown.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium))
                    Text("Nothing matches").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if clipboard.clips.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 20, weight: .medium))
                    Text("Things you copy show up here").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { outer in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                // Pinned first, then newest.
                                ForEach(Array(shown.enumerated()), id: \.element.id) { index, clip in
                                    ClipCard(clip: clip, highlighted: highlight == clip.id,
                                             number: numbered && index < 9 ? index + 1 : nil) {
                                        // ⌘ or ⇧: pick it (to act on several); a plain click puts it back to paste.
                                        let mods = NSEvent.modifierFlags
                                        if mods.contains(.command) || mods.contains(.shift) {
                                            withAnimation(.easeOut(duration: 0.12)) { clipboard.pick(clip, modifiers: mods, in: shown) }
                                        } else if !clipboard.selection.isEmpty {
                                            withAnimation(.easeOut(duration: 0.12)) { clipboard.selection = [] }
                                        } else {
                                            clipboard.copy(clip)
                                            viewModel.close()
                                        }
                                    }
                                    .id(clip.id)
                                    .scrollEdgeFade()
                                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                                }
                            }
                            .frame(height: outer.size.height)
                            .background(GeometryReader { inner in
                                Color.clear
                                    .onAppear { overflows = inner.size.width > outer.size.width + 1 }
                                    .onChange(of: inner.size.width > outer.size.width + 1) { _, o in overflows = o }
                            })
                        }
                        .onChange(of: highlight) { _, id in
                            guard let id else { return }
                            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) }
                        }
                    }
                }
                .horizontalScrollRegion("clipboard", in: viewModel, active: overflows)
            }
        }
        .onAppear {
            if viewModel.openReason == .keyboard { highlight = shown.first?.id }
            startKeys()
        }
        .onDisappear(perform: stopKeys)
        // A new search highlights its first match, so ↩ pastes it.
        .onChange(of: query) { _, _ in highlight = self.shown.first?.id }
        .onChange(of: kind) { _, _ in if highlight != nil { highlight = self.shown.first?.id } }
    }

    // MARK: Keys

    private func startKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated { handle(event) ? nil : event }
        }
    }

    private func stopKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = 0
    }

    /// Only keys meant for this notch's Clipboard pane, while it's the one showing.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window is NotchPanel, viewModel.isOpen, viewModel.tab == .shelf, viewModel.overlay == nil,
              settings.clipboardHistory else { return false }
        let mods = ClipboardKey.carbon(event.modifierFlags)
        if event.type == .flagsChanged {
            held = mods
            return false
        }
        let editor = event.window?.firstResponder as? NSTextView
        // ⌘C with words picked in the search field copies those words.
        if let editor, editor.selectedRange().length > 0, mods == UInt32(cmdKey), event.charactersIgnoringModifiers == "c" {
            return false
        }
        if let (key, digit) = ClipboardKey.match(event) {
            run(key, digit: digit)
            return true
        }
        let plain = mods & UInt32(controlKey | optionKey | cmdKey) == 0
        let code = Int(event.keyCode)
        if plain, [kVK_LeftArrow, kVK_UpArrow, kVK_RightArrow, kVK_DownArrow].contains(code) {
            move([kVK_LeftArrow, kVK_UpArrow].contains(code) ? -1 : 1, extend: mods & UInt32(shiftKey) != 0)
            return true
        }
        if plain, code == kVK_Escape, !query.isEmpty {
            query = "" // the first Esc clears the search; the next one backs out as usual
            return true
        }
        // Typing with the search field not focused still searches.
        guard editor == nil, plain else { return false }
        if event.keyCode == UInt16(kVK_Delete) {
            guard !query.isEmpty else { return false }
            query.removeLast()
            return true
        }
        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        query += chars
        return true
    }

    /// Moves the highlight; with ⇧, the picked clips run from where it was to where it lands.
    private func move(_ step: Int, extend: Bool) {
        let shown = shown
        guard !shown.isEmpty else { return }
        let current = highlight.flatMap { id in shown.firstIndex { $0.id == id } }
        let next = current.map { max(0, min(shown.count - 1, $0 + step)) } ?? 0
        withAnimation(.easeOut(duration: 0.12)) {
            if extend {
                if clipboard.selection.isEmpty { clipboard.pick(shown[current ?? next], modifiers: [], in: shown) }
                clipboard.pick(shown[next], modifiers: .shift, in: shown)
            }
            highlight = shown[next].id
        }
    }

    /// What a key acts on: everything picked, else the highlighted clip.
    private var targets: [ClipboardHistory.Clip] {
        let shown = shown
        if !clipboard.selection.isEmpty { return shown.filter { clipboard.selection.contains($0.id) } }
        return shown.filter { $0.id == highlight }
    }

    private func run(_ key: ClipboardKey, digit: Int?) {
        let shown = shown
        if key == .quickPaste {
            guard let digit, digit <= shown.count else { NSSound.beep(); return }
            clipboard.selection = []
            clipboard.paste(shown[digit - 1])
            return
        }
        let group = targets
        guard let first = group.first else {
            // Nothing highlighted yet: the first press shows where the keys will act.
            if !shown.isEmpty { withAnimation(.easeOut(duration: 0.12)) { highlight = shown[0].id } }
            return
        }
        switch key {
        case .paste:
            clipboard.selection = []
            group.count > 1 ? clipboard.pasteTogether(group) : clipboard.paste(first)
        case .copy:
            clipboard.selection = []
            if group.count > 1 { clipboard.copyTogether(group) } else { clipboard.copy(first) }
            viewModel.close()
        case .delete:
            // The highlight moves on to the clip after (or before) the ones removed.
            let ids = Set(group.map(\.id))
            let last = shown.lastIndex { ids.contains($0.id) } ?? 0
            let after = shown[(last + 1)...].first { !ids.contains($0.id) } ?? shown[..<last].last { !ids.contains($0.id) }
            group.count > 1 ? clipboard.remove(group) : clipboard.delete(first)
            highlight = after?.id
        case .pin:
            if group.count > 1 { clipboard.setPinned(group, !group.allSatisfy(\.pinned)) } else { clipboard.togglePin(first) }
        case .quickPaste:
            break
        }
    }
}

private struct ClipCard: View {
    let clip: ClipboardHistory.Clip
    /// Where the keyboard is.
    var highlighted = false
    /// Shown while quick paste's modifiers are held: the digit that pastes this clip.
    var number: Int?
    let action: () -> Void
    @EnvironmentObject private var clipboard: ClipboardHistory
    @State private var hovering = false
    /// What can be done with this copy beyond pasting it (worked out once per clip).
    @State private var suggestions: [ClipAction] = []
    /// A short "Added to Tasks" over the card after an action.
    @State private var flash: String?

    private func run(_ suggestion: ClipAction) {
        guard let message = suggestion.run() else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { flash = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.25)) { if flash == message { flash = nil } }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 4) {
                if let id = clip.sourceBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    AppIcon(bundlePath: url.path, size: 11)
                } else {
                    Image(systemName: clip.icon).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                }
                Text(Date().timeIntervalSince(clip.date) < 60 ? "now" : clip.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                Spacer(minLength: 0)
                if clip.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.orange)
                }
            }
        }
        .padding(8)
        .frame(width: 132)
        .frame(maxHeight: .infinity)
        .notchSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), active: hovering || highlighted)
        .overlay {
            if highlighted, !clipboard.selection.contains(clip.id) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.75), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let number, let combo = ClipboardKey.quickPaste.combo {
                Text(combo.modifierSymbols + "\(number)")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).frame(height: 16)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                    .padding(5)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if clipboard.selection.contains(clip.id) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5))
                    .allowsHitTesting(false)
            }
        }
        // Over the empty end of the bottom row (beside the time), not over what was copied.
        .overlay(alignment: .bottomTrailing) {
            if hovering, flash == nil {
                HStack(spacing: 2) {
                    // The most fitting action, one click away (the rest are on right-click).
                    if let first = suggestions.first {
                        Button { run(first) } label: {
                            Image(systemName: first.icon).font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(NotchIconButtonStyle(size: 20))
                        .help(first.title + (suggestions.count > 1 ? " · right-click for more" : ""))
                    }
                    Button { clipboard.paste(clip) } label: {
                        Image(systemName: "arrow.turn.down.left").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 20))
                    .help("Paste into \(FrontmostTracker.shared.userApp?.localizedName ?? "the app you're in")")
                    Button { clipboard.togglePin(clip) } label: {
                        Image(systemName: clip.pinned ? "pin.slash.fill" : "pin.fill").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 20))
                    .help(clip.pinned ? "Unpin" : "Pin: kept when you clear the history")
                    Button { clipboard.delete(clip) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 20))
                    .help("Remove")
                }
                .padding(3)
                .background(Capsule().fill(.black.opacity(0.6)))
                .padding(4)
            }
        }
        .overlay {
            if let flash {
                Label(flash, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(Color.green.opacity(0.85)))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture(perform: action)
        .onDrag {
            DragActivity.shared.active = true // shows AirDrop and Taildrop to drop it on
            return dragItem
        }
        .task(id: clip.id) { suggestions = ClipActions.suggestions(for: clip) }
        .contextMenu { ClipMenu(clip: clip, suggestions: suggestions, run: run) }
        .help("Click to copy · ⌘-click to select several")
    }

    @ViewBuilder private var content: some View {
        switch clip.kind {
        case .text:
            Text(clip.title)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(5)
        case .link:
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: "link").font(.system(size: 10, weight: .semibold)).foregroundStyle(.blue)
                Text(URL(string: clip.title)?.host() ?? clip.title)
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(clip.title).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
        case .image:
            if let image = clipboard.image(for: clip) {
                // Filled over a fixed-size base: a filled image on its own reports its overflowing
                // size, and the card grows past its neighbours to fit it.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        case .files:
            HStack(spacing: 6) {
                if let first = clip.filePaths?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first)).resizable().frame(width: 30, height: 30)
                }
                Text(clip.title).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
            }
        }
    }

    private var dragItem: NSItemProvider {
        switch clip.kind {
        case .files: NSItemProvider(object: URL(fileURLWithPath: clip.filePaths?.first ?? "") as NSURL)
        case .image: clipboard.image(for: clip).map { NSItemProvider(object: $0) } ?? NSItemProvider()
        default: NSItemProvider(object: (clip.text ?? "") as NSString)
        }
    }
}

/// Right-click on a copy: everything it can do, for every picked copy at once.
private struct ClipMenu: View {
    let clip: ClipboardHistory.Clip
    let suggestions: [ClipAction]
    let run: (ClipAction) -> Void
    @EnvironmentObject private var clipboard: ClipboardHistory

    private var app: String { FrontmostTracker.shared.userApp?.localizedName ?? "App" }

    var body: some View {
        let group = clipboard.targets(for: clip)
        if group.count > 1 {
            many(group)
        } else {
            one
        }
    }

    // MARK: Several

    @ViewBuilder private func many(_ group: [ClipboardHistory.Clip]) -> some View {
        Text("\(group.count) items")
        MenuItem("Paste Together into \(app)", "arrow.turn.down.left") { clipboard.pasteTogether(group) }
        MenuItem("Copy Together", "doc.on.doc") { clipboard.copyTogether(group) }
        MenuItem("Save All to Shelf", "tray.and.arrow.down") { group.forEach(clipboard.saveToShelf) }
        let files = group.flatMap { $0.filePaths ?? [] }.map { URL(fileURLWithPath: $0) }
        if !files.isEmpty {
            Divider()
            OpenWithMenu(urls: files)
            MenuItem("Quick Look", "eye") { QuickLookPreview.shared.show(files) }
            ShareLink(items: files) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        Divider()
        let pin = !group.allSatisfy(\.pinned)
        MenuItem(pin ? "Pin All" : "Unpin All", pin ? "pin" : "pin.slash") { clipboard.setPinned(group, pin) }
        MenuItem("Deselect", "circle.dashed") { clipboard.selection = [] }
        Divider()
        MenuItem("Remove \(group.count) Items", "trash", role: .destructive) { clipboard.remove(group) }
    }

    // MARK: One

    @ViewBuilder private var one: some View {
        MenuItem("Paste into \(app)", "arrow.turn.down.left") { clipboard.paste(clip) }
        MenuItem("Copy", "doc.on.doc") { clipboard.copy(clip) }
        if !suggestions.isEmpty {
            Divider()
            ForEach(suggestions) { suggestion in MenuItem(suggestion.title, suggestion.icon) { run(suggestion) } }
        }
        Divider()
        switch clip.kind {
        case .link:
            if let url = clip.text.flatMap({ URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                MenuItem("Open Link", "safari") { NSWorkspace.shared.open(url) }
                if let host = url.host() { Text(host) }
                if let link = VideoDownloader.webURL(url.absoluteString), VideoDownloader.isAvailable {
                    MenuItem("Download Video…", "arrow.down.circle") { VideoDownloader.shared.chooseQuality(for: link) }
                    MenuItem("Download Audio", "music.note") { VideoDownloader.shared.download(link, format: .audio, height: nil) }
                }
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
        case .files:
            let urls = (clip.filePaths ?? []).map { URL(fileURLWithPath: $0) }
            MenuItem("Open", "arrow.up.forward.square") { urls.forEach { NSWorkspace.shared.open($0) } }
            OpenWithMenu(urls: urls)
            MenuItem("Quick Look", "eye") { QuickLookPreview.shared.show(urls) }
            MenuItem("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            MenuItem(urls.count > 1 ? "Copy Paths" : "Copy Path", "point.topleft.down.to.point.bottomright.curvepath") { ShelfStore.copyPaths(urls) }
            ShareLink(items: urls) { Label("Share…", systemImage: "square.and.arrow.up") }
        case .image:
            if let url = clipboard.imageURL(for: clip) {
                MenuItem("Quick Look", "eye") { QuickLookPreview.shared.show([url]) }
                MenuItem("Copy Text in Image", "text.viewfinder") { clipboard.copyText(in: clip) }
                MenuItem("Remove Background", "person.crop.rectangle") { Cutout.run([url]) }
                OpenWithMenu(urls: [url])
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
        case .text:
            if let text = clip.text {
                let words = text.split(whereSeparator: \.isWhitespace).count
                Text("\(words) \(words == 1 ? "word" : "words") · \(text.count) characters")
                MenuItem("Search the Web", "magnifyingglass") { clipboard.searchWeb(clip) }
                MenuItem("Ask About It", "sparkles") {
                    NotchPresenter.shared.open(tab: .ask)
                    AssistantStore.shared.run("Explain this briefly: \(text.prefix(2000))")
                }
                let transforms = TextTransform.applicable(to: text).filter { $0 != .plain }
                if !transforms.isEmpty {
                    Menu {
                        ForEach(transforms) { t in
                            Button(t.title) {
                                clipboard.copy(clip, announce: false)
                                TextTransform.applyToClipboard(t)
                            }
                        }
                    } label: {
                        Label("Transform & Copy", systemImage: "textformat")
                    }
                }
                ShareLink(item: text) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
        }
        MenuItem("Save to Shelf", "tray.and.arrow.down") { clipboard.saveToShelf(clip) }
        Divider()
        MenuItem(clip.pinned ? "Unpin" : "Pin", clip.pinned ? "pin.slash" : "pin") { clipboard.togglePin(clip) }
        MenuItem("Select", "checkmark.circle") { clipboard.pick(clip, modifiers: .command, in: clipboard.clips) }
        Divider()
        MenuItem("Remove", "trash", role: .destructive) { clipboard.delete(clip) }
    }
}

// MARK: - Video downloads

/// A yt-dlp download in the Downloads pane: progress while it runs, then the file (drag it out).
private struct VideoJobTile: View {
    let job: VideoDownloader.Job
    @EnvironmentObject private var videos: VideoDownloader
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: job.format == .audio ? "music.note" : "play.rectangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                Text(job.displayTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(0.88))
            }
            Spacer(minLength: 0)
            status
        }
        .padding(8)
        .frame(width: 150)
        .frame(maxHeight: .infinity)
        .notchSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), active: hovering)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { job.isActive ? videos.cancel(job) : videos.dismiss(job) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(NotchIconButtonStyle(size: 18))
                .background(Circle().fill(.black.opacity(0.6)))
                .padding(4)
                .help(job.isActive ? "Cancel" : "Hide")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if case .done(let url) = job.state { NSWorkspace.shared.open(url) } }
        .onDrag {
            if case .done(let url) = job.state { return NSItemProvider(object: url as NSURL) }
            return NSItemProvider(object: job.url as NSURL)
        }
        .contextMenu {
            if case .done(let url) = job.state {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Open Link") { NSWorkspace.shared.open(job.url) }
            if case .failed = job.state {
                Button("Try Again") { videos.dismiss(job); videos.download(job.url, format: job.format) }
                Button("Update yt-dlp") { videos.upgrade() }
            }
        }
        .help(job.url.absoluteString)
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .starting:
            Text("Starting…").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
        case .downloading, .processing:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: job.progress).progressViewStyle(.linear).tint(.red).controlSize(.small)
                Text(job.state == .processing ? "Finishing up…" : detail)
                    .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
        case .done(let url):
            Label(url.pathExtension.uppercased() + (job.height.map { " · \($0)p" } ?? "") + " · double-click to open", systemImage: "checkmark.circle.fill")
                .font(.system(size: 9.5)).foregroundStyle(.green).lineLimit(1)
        case .failed(let message):
            Text(message).font(.system(size: 9.5)).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private var detail: String {
        var parts = ["\(Int((job.progress * 100).rounded()))%"]
        if job.speed > 0 { let r = formatRate(job.speed); parts.append("\(r.value) \(r.unit)") }
        if let eta = job.eta, eta > 0 { parts.append(eta >= 60 ? "\(eta / 60)m \(eta % 60)s" : "\(eta)s") }
        return parts.joined(separator: " · ")
    }
}

/// Every conversion for files dropped on "More…": new formats on the first row, changes that keep
/// the format after them. Picking one starts it and goes back to the shelf.
private struct ConvertPicker: View {
    let urls: [URL]
    @EnvironmentObject private var shelf: ShelfStore

    var body: some View {
        let ops = MediaConverter.operations(for: urls)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold)).foregroundStyle(.purple)
                Text(urls.count == 1 ? "Convert “\(urls[0].lastPathComponent)” to…" : "Convert \(urls.count) files to…")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel") { shelf.convertPicker = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(ops.filter { !$0.isEdit } + ops.filter(\.isEdit)) { op in
                        ConvertChoice(op: op) {
                            MediaConverter.shared.convert(urls, op)
                            shelf.convertPicker = nil
                        }
                    }
                }
            }
        }
    }
}

private struct ConvertChoice: View {
    let op: MediaConverter.Operation
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: op.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? .purple : .white.opacity(0.6))
                    .frame(width: 14)
                Text(op.shortTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .notchSurface(RoundedRectangle(cornerRadius: 8, style: .continuous), active: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(op.title)
    }
}

/// A conversion in progress on the shelf: one file, or a batch as "3 of 12".
private struct ConvertJobTile: View {
    let batch: MediaConverter.BatchStatus
    @EnvironmentObject private var converter: MediaConverter
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 3)
                if let p = batch.progress {
                    Circle().trim(from: 0, to: max(0.03, p))
                        .stroke(Color.purple, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: p)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Image(systemName: batch.operation.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.purple)
            }
            .frame(width: 44, height: 44)
            Text(batch.operation.shortTitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(6)
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .notchSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), active: hovering)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    if batch.total > 1 { converter.cancel(batch: batch.id) } else if let job = batch.jobs.first { converter.cancel(job) }
                } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(NotchIconButtonStyle(size: 18))
                    .help(batch.total > 1 ? "Stop the rest" : "Cancel")
            }
        }
        .onHover { hovering = $0 }
        .help(batch.jobs.map(\.source.lastPathComponent).joined(separator: "\n"))
    }

    private var detail: String {
        if batch.total > 1 { return "\(batch.finished + 1) of \(batch.total)" }
        if batch.jobs.first?.state == .queued { return "Waiting…" }
        return batch.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? batch.jobs.first?.source.lastPathComponent ?? ""
    }
}
