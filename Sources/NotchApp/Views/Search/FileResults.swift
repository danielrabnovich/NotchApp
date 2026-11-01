import SwiftUI

struct FileResults: View {
    @ObservedObject private var access = FolderAccess.shared
    @ObservedObject private var images = ImageIndex.shared
    let job: AssistantStore.Job
    let accent: Color
    @Binding var selection: Int

    var body: some View {
        if !job.files.isEmpty {
            let index = min(selection, job.files.count - 1)
            HStack(alignment: .top, spacing: 16) {
                // The selected match, previewed: ↑↓ (or a click in the list) changes it.
                BestFile(hit: job.files[index],
                         label: index == 0 ? (job.confident ? "Best match" : "Closest match") : "Match \(index + 1) of \(job.files.count)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                if job.files.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Text("\(job.files.count) matches")
                                .contentTransition(.numericText())
                            if job.findingMore {
                                Text("·")
                                SearchingCapsule(height: 9)
                                Text("finding more")
                            } else if images.isIndexing {
                                // Pictures not looked at yet can't match; say so.
                                Text("· \(images.remaining.formatted()) pictures still indexing")
                                    .help("Picture search finds the ones done so far")
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 8)
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 0) {
                                    ForEach(Array(job.files.enumerated()), id: \.element.id) { i, hit in
                                        FileRow(hit: hit, selected: i == index) {
                                            selection = i
                                            QuickLook.shared.follow(job.files.map(\.url), at: i)
                                        }
                                        .id(i)
                                    }
                                }
                            }
                            .onChange(of: index) { _, i in
                                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i) }
                            }
                        }
                    }
                    .frame(width: 230, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 6) {
                Text("No matching file").font(.system(size: 13, weight: .medium))
                if !access.missing.isEmpty {
                    Text("NotchApp can't see \(access.missing.map(\.name).joined(separator: ", ")) yet.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Button("Allow in System Settings") { FolderAccess.openPrivacySettings() }
                        .buttonStyle(NotchPillButtonStyle(primary: true, height: 24))
                        .padding(.top, 4)
                } else {
                    Text("Try a word that might be in its name").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct BestFile: View {
    let hit: FileHit
    let label: String
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Sized to the picture so a wide screenshot isn't a sliver in a tall box.
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: hit.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(thumbnail == nil ? 0 : 0.12), lineWidth: 1))
                .frame(maxWidth: 96, maxHeight: 108)
                .frame(width: 96, height: 108, alignment: .top)
                .id(hit.url)
                .transition(.opacity)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Text(hit.url.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(location)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.head)
                if let reason = hit.reason {
                    Text(reason.prefix(1).uppercased() + reason.dropFirst())
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                HStack(spacing: 6) {
                    button("Open", primary: true) { NSWorkspace.shared.open(hit.url) }
                    button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
                        .help("⌘↩")
                    ShelfButton(url: hit.url)
                }
                .padding(.top, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(hit.url) }
        .onDrag { NSItemProvider(object: hit.url as NSURL) }
        .task(id: hit.url) {
            thumbnail = nil
            thumbnail = await Thumbnail.load(hit.url, size: 300)
        }
    }

    private var location: String {
        hit.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func button(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(NotchPillButtonStyle(primary: primary, height: 24))
    }
}

/// "Add to Shelf" that turns into a checkmark once the file is on the shelf.
private struct ShelfButton: View {
    let url: URL
    @EnvironmentObject private var shelf: ShelfStore

    var body: some View {
        let added = shelf.items.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
        Button {
            guard !added else { return }
            withAnimation(Motion.small.animation) { ShelfStore.shared.add([url]) }
        } label: {
            HStack(spacing: 4) {
                if added {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).transition(.scale.combined(with: .opacity))
                }
                Text(added ? "On Shelf" : "Add to Shelf")
            }
            .contentTransition(.opacity)
        }
        // The same pill as Open and Show in Finder beside it.
        .buttonStyle(NotchPillButtonStyle(height: 24))
        .help(added ? "Already on your shelf" : "Keep it on the shelf")
    }
}

struct FileRow: View {
    let hit: FileHit
    var selected = false
    /// A click previews the file; a double-click opens it.
    var select: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hit.url.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.url.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hit.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.14 : hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(hit.url) }
        .onTapGesture(count: 1) { select() }
        .onDrag { NSItemProvider(object: hit.url as NSURL) }
        .help(hit.reason ?? hit.url.path)
        .contextMenu {
            MenuItem("Open", "arrow.up.forward.square") { NSWorkspace.shared.open(hit.url) }
            OpenWithMenu(urls: [hit.url])
            MenuItem("Quick Look", "eye") { QuickLookPreview.shared.show([hit.url]) }
            MenuItem("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
            Divider()
            MenuItem("Copy", "doc.on.doc") { ShelfStore.copy([hit.url]) }
            MenuItem("Copy Path", "point.topleft.down.to.point.bottomright.curvepath") { ShelfStore.copyPaths([hit.url]) }
            ShareLink(item: hit.url) { Label("Share…", systemImage: "square.and.arrow.up") }
            let onShelf = ShelfStore.shared.items.contains { $0.url == hit.url }
            MenuItem(onShelf ? "On Shelf" : "Add to Shelf", onShelf ? "checkmark" : "tray.and.arrow.down") { ShelfStore.shared.add([hit.url]) }
        }
    }
}
