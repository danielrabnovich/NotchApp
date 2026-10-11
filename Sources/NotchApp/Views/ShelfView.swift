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
                } else if shelf.items.isEmpty && !hasPanes {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        header
                        if showingClipboard {
                            ClipboardStrip(viewModel: viewModel)
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
                                ForEach(converter.jobs.filter(\.isActive).prefix(2)) { ConvertJobTile(job: $0) }
                                // Quick drops first (newest first), then what's pinned to stay.
                                TileStrip(items: shelf.stack + shelf.items.filter(\.pinned), regionID: "shelf", viewModel: viewModel) {
                                    ShelfTile(item: $0, kind: .shelf)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: taildrop.pending.isEmpty)

            if settings.airDropZone || showsTaildrop {
                VStack(spacing: 8) {
                    if settings.airDropZone { AirDropZone(compact: showsTaildrop) }
                    if showsTaildrop { TaildropZone(compact: settings.airDropZone) }
                }
                .frame(width: 104)
            }
        }
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
            if showingClipboard {
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
    @State private var hovering = false

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
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 72, height: 26, alignment: .top)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0)))
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
        .overlay(alignment: .topTrailing) {
            if hovering && kind == .shelf {
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
        .onDrag {
            // A saved web link drops as the link itself (into a browser, Messages, a doc…).
            if let web = ShelfStore.webLink(in: item.url) { return NSItemProvider(object: web as NSURL) }
            return NSItemProvider(object: item.url as NSURL)
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            if kind == .shelf {
                // Pinned files stay; unpinned ones are quick drops that leave once used or expired.
                Button(item.pinned ? "Unpin" : "Pin to Shelf") { ShelfStore.shared.setPinned(item, !item.pinned) }
            }
            if kind == .download {
                Button("Add to Shelf") { ShelfStore.shared.add([item.url]) }
            }
            Button("AirDrop") { ShelfStore.airDrop([item.url]) }
            let conversions = MediaConverter.operations(for: [item.url])
            if !conversions.isEmpty {
                Menu("Convert") {
                    ForEach(conversions) { op in
                        Button(op.title) { MediaConverter.shared.convert([item.url], op) }
                    }
                }
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item.url as NSURL])
            }
            Divider()
            if kind == .shelf {
                Button("Remove from Shelf") { ShelfStore.shared.remove(item) }
            } else {
                Button("Move to Trash") { DownloadsStore.shared.moveToTrash(item) }
            }
        }
        .help(item.url.path)
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
private struct ClipboardStrip: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var clipboard: ClipboardHistory
    @State private var overflows = false

    var body: some View {
        if clipboard.clips.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 20, weight: .medium))
                Text("Things you copy show up here").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { outer in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        // Pinned first, then newest.
                        ForEach(clipboard.pinned + clipboard.clips.filter { !$0.pinned }) { clip in
                            ClipCard(clip: clip) {
                                clipboard.copy(clip)
                                viewModel.close()
                            }
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
            }
            .horizontalScrollRegion("clipboard", in: viewModel, active: overflows)
        }
    }
}

private struct ClipCard: View {
    let clip: ClipboardHistory.Clip
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
        .notchSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), active: hovering)
        .overlay(alignment: .topTrailing) {
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
        .onDrag { dragItem }
        .task(id: clip.id) { suggestions = ClipActions.suggestions(for: clip) }
        .contextMenu {
            Button("Copy") { clipboard.copy(clip) }
            if !suggestions.isEmpty {
                Divider()
                ForEach(suggestions) { suggestion in
                    Button { run(suggestion) } label: { Label(suggestion.title, systemImage: suggestion.icon) }
                }
            }
            if let link = clip.kind == .link ? clip.text.flatMap(VideoDownloader.webURL) : nil, VideoDownloader.isAvailable {
                Button("Download Video…") { VideoDownloader.shared.chooseQuality(for: link) }
                Button("Download Audio") { VideoDownloader.shared.download(link, format: .audio, height: nil) }
            }
            if clip.kind == .text, let text = clip.text {
                Menu("Transform") {
                    ForEach(TextTransform.applicable(to: text).filter { $0 != .plain }) { t in
                        Button(t.title) {
                            clipboard.copy(clip)
                            TextTransform.applyToClipboard(t)
                        }
                    }
                }
            }
            Divider()
            Button(clip.pinned ? "Unpin" : "Pin") { clipboard.togglePin(clip) }
            Button("Remove") { clipboard.delete(clip) }
        }
        .help("Click to copy")
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

/// A conversion in progress on the shelf.
private struct ConvertJobTile: View {
    let job: MediaConverter.Job
    @EnvironmentObject private var converter: MediaConverter
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 3)
                if let p = job.progress {
                    Circle().trim(from: 0, to: max(0.03, p))
                        .stroke(Color.purple, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold)).foregroundStyle(.purple)
            }
            .frame(width: 44, height: 44)
            Text(job.operation.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Text(job.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? job.source.lastPathComponent)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(6)
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0.05)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { converter.cancel(job) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(NotchIconButtonStyle(size: 18))
                    .help("Cancel")
            }
        }
        .onHover { hovering = $0 }
        .help(job.source.path)
    }
}
