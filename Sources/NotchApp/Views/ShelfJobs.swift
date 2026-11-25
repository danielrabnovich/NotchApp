import Carbon.HIToolbox
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// The shelf's jobs and pickers: video downloads, conversions, file thumbnails and LocalSend.

// MARK: - Video downloads

/// A yt-dlp download in the Downloads pane: progress while it runs, then the file (drag it out).
struct VideoJobTile: View {
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
                MenuItem("Open", "arrow.up.forward.square") { NSWorkspace.shared.open(url) }
                MenuItem("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            MenuItem("Open Link", "safari") { NSWorkspace.shared.open(job.url) }
            if case .failed = job.state {
                MenuItem("Try Again", "arrow.clockwise") { videos.dismiss(job); videos.download(job.url, format: job.format) }
                MenuItem("Update yt-dlp", "arrow.down.circle") { videos.upgrade() }
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

/// Every conversion for files dropped on "More…" (or picked on the shelf), in two steps: what to
/// make, new formats first, then how to save it. With only one way to save, picking starts it.
struct ConvertPicker: View {
    let urls: [URL]
    @EnvironmentObject private var shelf: ShelfStore
    @State private var chosen: MediaConverter.Operation?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if chosen != nil {
                    Button { withAnimation(Motion.pane.animation) { chosen = nil } } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                    .help("Back")
                } else {
                    Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold)).foregroundStyle(.purple)
                }
                Text(heading)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel") { shelf.convertPicker = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if let chosen {
                savingStep(chosen)
                    .transition(.opacity.combined(with: .offset(x: 16)))
            } else {
                operationStep
                    .transition(.opacity.combined(with: .offset(x: -16)))
            }
        }
    }

    private var heading: String {
        let files = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) files"
        guard let chosen else { return "Convert \(files) to…" }
        return "\(chosen.shortTitle): save \(urls.count == 1 ? "it" : "them") how?"
    }

    private var operationStep: some View {
        let ops = MediaConverter.operations(for: urls)
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(ops.filter { !$0.isEdit } + ops.filter(\.isEdit)) { op in
                    ConvertChoice(op: op) {
                        if MediaConverter.savings(for: urls, op) == [.copy] {
                            start(op, .copy)
                        } else {
                            withAnimation(Motion.pane.animation) { chosen = op }
                        }
                    }
                }
            }
        }
    }

    private func savingStep(_ op: MediaConverter.Operation) -> some View {
        let first = urls[0]
        let more = urls.count > 1 ? " +\(urls.count - 1)" : ""
        return HStack(spacing: 8) {
            ForEach(MediaConverter.savings(for: urls, op), id: \.self) { saving in
                let name = MediaConverter.previewName(for: first, op, saving) + more
                switch saving {
                case .copy:
                    SavingChoice(symbol: "plus.square.on.square", title: "Save a Copy", detail: name) { start(op, saving) }
                case .sameName:
                    SavingChoice(symbol: "textformat", title: "Copy, Same Name", detail: name) { start(op, saving) }
                case .replace:
                    SavingChoice(symbol: "arrow.triangle.2.circlepath", title: "Replace Original", detail: "\(name) · old to Trash",
                                 tint: .orange) { start(op, saving) }
                }
            }
        }
    }

    private func start(_ op: MediaConverter.Operation, _ saving: MediaConverter.Saving) {
        MediaConverter.shared.convert(urls, op, saving: saving)
        shelf.convertPicker = nil
    }
}

/// One way to save, as a card in the picker's second step.
private struct SavingChoice: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color = .purple
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hovering ? tint : .white.opacity(0.7))
                Spacer(minLength: 0)
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .notchSurface(RoundedRectangle(cornerRadius: 10, style: .continuous), active: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(detail)
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
        .help(op.note.map { "\(op.title) · \($0)" } ?? op.title)
    }
}

/// A conversion in progress on the shelf: one file, or a batch as "3 of 12".
struct ConvertJobTile: View {
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

/// A file's preview from Quick Look (a picture, a PDF's first page, a document's own icon), made
/// once per file and kept; the file's icon stands in until it's ready.
struct FileThumbnail: View {
    let path: String
    /// Fill the frame (a picture) rather than fit inside it (a page, an icon).
    var fill = false
    var size: CGFloat = 180
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().aspectRatio(contentMode: .fit).padding(6)
                }
            }
            .clipped()
            .task(id: path) {
                let key = "\(path)#\(Int(size))" as NSString
                if let hit = Self.cache.object(forKey: key) { image = hit; return }
                let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size),
                                                          scale: 2, representationTypes: .thumbnail)
                guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return }
                Self.cache.setObject(rep.nsImage, forKey: key)
                image = rep.nsImage
            }
    }
}

/// Several files as a little fanned stack (the first three), with how many there are; it opens
/// wider under the pointer so each one can be seen.
struct FileFan: View {
    let paths: [String]
    var spread = false

    var body: some View {
        let shown = Array(paths.prefix(3))
        GeometryReader { geo in
            let side = min(geo.size.height - 4, 52)
            ZStack {
                ForEach(Array(shown.enumerated().reversed()), id: \.offset) { i, path in
                    // The first file on top, the others fanned out behind it to either side.
                    let slot = CGFloat(i == 0 ? 0 : (i == 1 ? -1 : 1))
                    FileThumbnail(path: path, fill: true, size: 120)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                        .rotationEffect(.degrees(Double(slot) * (spread ? 14 : 7)), anchor: .bottom)
                        .offset(x: slot * (spread ? side * 0.62 : side * 0.28))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .topTrailing) {
                Text("\(paths.count)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(.white.opacity(0.9)))
            }
            .animation(Motion.small.animation, value: spread)
        }
    }
}

/// Pick which LocalSend device gets the files: whoever answered the hello on this network.
struct LocalSendPicker: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var localSend = LocalSendService.shared
    private static let tint = Color(red: 0.0, green: 0.66, blue: 0.6)

    var body: some View {
        let count = localSend.pending.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Self.tint)
                Text(count == 1 ? "Send “\(localSend.pending[0].lastPathComponent)” with LocalSend to…" : "Send \(count) files with LocalSend to…")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(localSend.scanning ? "Looking…" : "Look Again") { localSend.scan() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    .disabled(localSend.scanning)
                Button("Cancel") { localSend.cancelPending() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            if localSend.devices.isEmpty {
                VStack(spacing: 4) {
                    Text(localSend.scanning ? "Looking for LocalSend on this network…" : "No LocalSend devices answered")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    if !localSend.scanning {
                        Text("Open LocalSend on the other device, on the same Wi-Fi.")
                            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(localSend.devices) { device in
                            Button { localSend.send(to: device) } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: device.icon).font(.system(size: 22)).frame(height: 26)
                                    Text(device.alias).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    Text(device.deviceModel ?? device.ip).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(width: 86, height: 84)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Self.tint.opacity(0.5), lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .horizontalScrollRegion("localsend.devices", in: viewModel)
            }
        }
    }
}
