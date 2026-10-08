import SwiftUI
import UniformTypeIdentifiers

enum ShelfPane: String {
    case shelf, downloads
    static let options: [(value: ShelfPane, title: String)] = [(.shelf, "Shelf"), (.downloads, "Downloads")]
}

struct ShelfView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var shelf: ShelfStore
    @EnvironmentObject private var downloads: DownloadsStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var taildrop: TaildropService
    @AppStorage("shelf.pane") private var pane: ShelfPane = .shelf

    private var showsTaildrop: Bool { settings.taildropZone && TaildropService.cli != nil }

    private var showingDownloads: Bool { settings.downloadsEnabled && pane == .downloads }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if !taildrop.pending.isEmpty {
                    DevicePicker(viewModel: viewModel)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if shelf.items.isEmpty && !settings.downloadsEnabled {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        header
                        if showingDownloads {
                            if downloads.items.isEmpty {
                                placeholder(icon: "arrow.down.circle", text: "No downloads yet")
                            } else {
                                TileStrip(items: downloads.items, regionID: "downloads", viewModel: viewModel) {
                                    ShelfTile(item: $0, kind: .download)
                                }
                            }
                        } else if shelf.items.isEmpty {
                            emptyState
                        } else {
                            TileStrip(items: shelf.items, regionID: "shelf", viewModel: viewModel) {
                                ShelfTile(item: $0, kind: .shelf)
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
            if settings.downloadsEnabled {
                PaneSwitcher(selection: $pane, options: ShelfPane.options)
            } else {
                Text("Shelf")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if showingDownloads {
                Button("Open Folder") { NSWorkspace.shared.open(downloads.folder) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else if !shelf.items.isEmpty {
                Button("Clear") { withAnimation(.spring(response: 0.3)) { shelf.clear() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
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
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            if kind == .download {
                Button("Add to Shelf") { ShelfStore.shared.add([item.url]) }
            }
            Button("AirDrop") { ShelfStore.airDrop([item.url]) }
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
