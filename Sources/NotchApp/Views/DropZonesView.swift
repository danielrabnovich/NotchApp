import SwiftUI
import UniformTypeIdentifiers

/// Shown while something is dragged over the notch: pick where it goes.
struct DropZonesView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let preview = viewModel.dragPreview
        HStack(spacing: 10) {
            if settings.tasksEnabled {
                DropBin(icon: "checklist", title: "Add to Tasks",
                        detail: preview?.taskTitle.map { "“\($0)”" } ?? "Make it a task",
                        detailIcon: preview?.icon,
                        tint: .green,
                        enabled: preview?.taskTitle != nil) {
                    let new = TaskStore.tasks(from: NSPasteboard(name: .drag))
                    guard !new.isEmpty else { return false }
                    new.forEach { TaskStore.shared.add($0) }
                    finish(on: .tasks)
                    return true
                }
            }
            if VideoDownloader.isAvailable, let link = preview?.webLink {
                DropBin(icon: "arrow.down.circle.fill", title: "Download Video",
                        detail: link.host()?.replacingOccurrences(of: "www.", with: "") ?? "With yt-dlp",
                        detailIcon: "link", tint: .red, enabled: true) {
                    // ⌥ while dropping saves just the audio.
                    let audio = NSEvent.modifierFlags.contains(.option)
                    VideoDownloader.shared.download(link, format: audio ? .audio : .video)
                    finish(on: settings.shelfEnabled ? .shelf : viewModel.tab)
                    if settings.shelfEnabled { UserDefaults.standard.set(ShelfPane.downloads.rawValue, forKey: "shelf.pane") }
                    return true
                }
                .help("Hold ⌥ while dropping to save only the audio")
            }
            if settings.shelfEnabled {
                DropBin(icon: "tray.and.arrow.down.fill", title: "Shelf",
                        detail: preview?.hasFiles == true ? "Keep it handy" : "Files only",
                        detailIcon: nil, tint: .orange,
                        enabled: preview?.hasFiles == true) {
                    guard ShelfStore.shared.addDrop(from: NSPasteboard(name: .drag)) else { return false }
                    finish(on: .shelf)
                    return true
                }
                DropBin(icon: "wand.and.stars", title: "Convert",
                        detail: preview?.hasFiles == true ? "Compress, GIF, JPEG…" : "Files only",
                        detailIcon: nil, tint: .purple, enabled: preview?.hasFiles == true) {
                    let urls = NSPasteboard(name: .drag)
                        .readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                    guard !urls.isEmpty else { return false }
                    viewModel.isDragActive = false
                    // The menu waits for the drop to finish first.
                    DispatchQueue.main.async { MediaConverter.shared.offer(urls) }
                    return true
                }
                .frame(width: 120)
                if settings.airDropZone {
                    DropBin(icon: "dot.radiowaves.left.and.right", image: SystemIcons.airDrop, title: "AirDrop",
                            detail: preview?.hasFiles == true ? "Send nearby" : "Files only",
                            detailIcon: nil, tint: .blue,
                            enabled: preview?.hasFiles == true) {
                        let urls = NSPasteboard(name: .drag)
                            .readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                        guard !urls.isEmpty else { return false }
                        DispatchQueue.main.async { ShelfStore.airDrop(urls) }
                        viewModel.isDragActive = false
                        return true
                    }
                    .frame(width: 120)
                }
                if settings.taildropZone && TaildropService.cli != nil {
                    DropBin(icon: "paperplane.fill", image: SystemIcons.tailscale, title: "Taildrop",
                            detail: preview?.hasFiles == true ? "Send to your devices" : "Files only",
                            detailIcon: nil, tint: TaildropPalette.accent,
                            enabled: preview?.hasFiles == true) {
                        let urls = NSPasteboard(name: .drag)
                            .readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                        guard !urls.isEmpty else { return false }
                        TaildropService.shared.offer(urls)
                        finish(on: .shelf)
                        return true
                    }
                    .frame(width: 120)
                }
            }
        }
        // Room for a bin to grow when something's over it (3%): the outer ones would otherwise
        // push their borders past the notch's edge.
        .padding(5)
    }

    private func finish(on tab: NotchTab) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            viewModel.isDragActive = false
            viewModel.tab = tab
            viewModel.pageOffset = 0
        }
        Haptics.level()
    }
}

private struct DropBin: View {
    let icon: String
    /// A real app icon to show instead of the symbol (AirDrop, Tailscale).
    var image: NSImage? = nil
    let title: String
    let detail: String
    let detailIcon: String?
    let tint: Color
    let enabled: Bool
    let onDrop: () -> Bool

    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(targeted ? tint.opacity(0.28) : .white.opacity(enabled ? 0.06 : 0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(targeted ? tint : .white.opacity(enabled ? 0.18 : 0.08),
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [6, 5]))
            )
            .overlay {
                VStack(spacing: 6) {
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().frame(width: 30, height: 30)
                                .opacity(enabled ? 1 : 0.4)
                                .scaleEffect(targeted ? 1.1 : 1)
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(targeted ? tint : .white.opacity(enabled ? 0.85 : 0.3))
                                .symbolEffect(.bounce, value: targeted)
                        }
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
                    HStack(spacing: 4) {
                        if let detailIcon, enabled {
                            Image(systemName: detailIcon).font(.system(size: 9))
                        }
                        Text(detail)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(enabled ? 0.55 : 0.25))
                    .padding(.horizontal, 12)
                }
            }
            .scaleEffect(targeted ? 1.03 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: targeted)
            .onDrop(of: [UTType.item], isTargeted: Binding(get: { targeted }, set: { targeted = $0 && enabled })) { _ in
                enabled ? onDrop() : false
            }
    }
}
