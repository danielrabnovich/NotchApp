import AppKit
import AVFoundation
import AVKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// The Shelf's file tools that aren't conversions: PDFs combined or split, a clip trimmed, and the
/// hidden details (where a photo was taken, the camera, the editing app) taken off before sharing.
/// Each result is saved beside its source and put on the Shelf; the source is left as it was.
@MainActor
enum ShelfTools {
    // MARK: PDFs

    static func isPDF(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) == true }

    /// PDFs and pictures, in the Shelf's order, can become one PDF: a picture is a page of its own.
    static func canCombine(_ urls: [URL]) -> Bool {
        urls.count > 1 && urls.allSatisfy { isPDF($0) || MediaConverter.kind(of: $0) == .image }
    }

    /// Pages in a PDF, remembered (the Shelf's menu is rebuilt on every redraw).
    static func pageCount(_ url: URL) -> Int {
        if let hit = pages[url.path] { return hit }
        let count = PDFDocument(url: url)?.pageCount ?? 0
        if pages.count > 100 { pages.removeAll() }
        pages[url.path] = count
        return count
    }
    private static var pages: [String: Int] = [:]

    static func combine(_ urls: [URL]) {
        let out = PDFDocument()
        for url in urls {
            if isPDF(url), let doc = PDFDocument(url: url) {
                for i in 0..<doc.pageCount { if let page = doc.page(at: i) { out.insert(page, at: out.pageCount) } }
            } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                out.insert(page, at: out.pageCount)
            }
        }
        guard out.pageCount > 0, let first = urls.first else { return failed("Couldn't combine these") }
        let target = ShelfStore.free(first.deletingLastPathComponent()
            .appendingPathComponent(first.deletingPathExtension().lastPathComponent + " combined").appendingPathExtension("pdf"))
        guard out.write(to: target) else { return failed("Couldn't save the PDF") }
        done([target], title: "Combined into one PDF", detail: "\(out.pageCount) pages · \(target.lastPathComponent)")
    }

    /// A page per file, in a folder named after the PDF; the folder goes on the Shelf.
    static func split(_ url: URL) {
        guard let doc = PDFDocument(url: url), doc.pageCount > 1 else { return failed("Nothing to split") }
        let base = url.deletingPathExtension().lastPathComponent
        let folder = ShelfStore.free(url.deletingLastPathComponent().appendingPathComponent(base + " pages"))
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return failed("Couldn't make the folder") }
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let one = PDFDocument()
            one.insert(page, at: 0)
            let number = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
            one.write(to: folder.appendingPathComponent("\(base) \(number).pdf"))
        }
        done([folder], title: "Split into \(doc.pageCount) pages", detail: folder.lastPathComponent)
    }

    // MARK: Hidden details

    /// Pictures, and the movie and sound files macOS can write back without encoding them again.
    static func canStrip(_ url: URL) -> Bool {
        if MediaConverter.kind(of: url) == .image { return !MediaConverter.isAnimated(url) && url.pathExtension.lowercased() != "svg" }
        return ["mov", "mp4", "m4v", "m4a"].contains(url.pathExtension.lowercased())
    }

    static func strip(_ urls: [URL]) {
        Task {
            var made: [URL] = []
            for url in urls where canStrip(url) {
                let target = ShelfStore.free(url.deletingLastPathComponent()
                    .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (clean)").appendingPathExtension(url.pathExtension))
                let ok = MediaConverter.kind(of: url) == .image ? stripImage(url, to: target) : await stripMovie(url, to: target)
                if ok { made.append(target) }
            }
            guard !made.isEmpty else { return failed("Couldn't remove the details") }
            done(made, title: "Location and details removed", detail: made.count == 1 ? made[0].lastPathComponent : "\(made.count) files")
        }
    }

    /// The picture's bytes copied as they are (a JPEG isn't compressed again), without its EXIF,
    /// GPS, XMP or IPTC; only which way up it goes is kept, so it doesn't turn on its side.
    private static func stripImage(_ url: URL, to target: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source),
              let dest = CGImageDestinationCreateWithURL(target as CFURL, type, 1, nil) else { return false }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var options: [CFString: Any] = [kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                                        kCGImageDestinationMergeMetadata: false,
                                        kCGImageMetadataShouldExcludeGPS: true,
                                        kCGImageMetadataShouldExcludeXMP: true]
        if let orientation = props?[kCGImagePropertyOrientation] { options[kCGImageDestinationOrientation] = orientation }
        var error: Unmanaged<CFError>?
        if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) { return true }
        // Some types can't be copied losslessly; then the pixels are written again without properties.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let again = CGImageDestinationCreateWithURL(target as CFURL, type, 1, nil) else { return false }
        let orientation = props?[kCGImagePropertyOrientation].map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(again, image, orientation as CFDictionary)
        return CGImageDestinationFinalize(again)
    }

    /// Passed through untouched, with the file's own metadata (location, device, software) left out.
    private static func stripMovie(_ url: URL, to target: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        session.metadata = []
        session.metadataItemFilter = .forSharing()
        let type: AVFileType = switch url.pathExtension.lowercased() { case "mp4": .mp4; case "m4v": .m4v; case "m4a": .m4a; default: .mov }
        return await session.write(to: target, as: type)
    }

    // MARK: Trimming

    static func canTrim(_ url: URL) -> Bool { ["mov", "mp4", "m4v", "m4a"].contains(url.pathExtension.lowercased()) }

    /// QuickTime's own trimmer (the yellow handles people already know), in a small window; the
    /// kept part is copied out as it is, so a trim takes a moment and loses nothing.
    static func trim(_ url: URL) { Trimmer.shared.open(url) }

    // MARK: Results

    fileprivate static func done(_ urls: [URL], title: String, detail: String) {
        if AppSettings.shared.shelfEnabled { ShelfStore.shared.add(urls, copy: false) }
        ActivityCenter.shared.show(.notice(title: title, detail: detail, icon: "wand.and.stars"), for: 4)
    }

    fileprivate static func failed(_ why: String) {
        ActivityCenter.shared.show(.notice(title: why, detail: "The original is unchanged", icon: "exclamationmark.triangle.fill", tone: .warning), for: 4)
    }
}

@MainActor
private final class Trimmer: NSObject, NSWindowDelegate {
    static let shared = Trimmer()
    private var window: NSWindow?
    private var source: URL?

    func open(_ url: URL) {
        window?.close()
        let asset = AVURLAsset(url: url)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        let audioOnly = url.pathExtension.lowercased() == "m4a"
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: audioOnly ? 120 : 460),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Trim " + url.lastPathComponent
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self
        w.center()
        window = w
        source = url
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // The trimmer needs the item ready before it will start.
        Task { @MainActor in
            _ = try? await asset.load(.duration)
            guard view.canBeginTrimming else { return }
            let result = await view.beginTrimming()
            guard result == .okButton, let item = player.currentItem else { return self.close() }
            let range = CMTimeRange(start: item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime : .zero,
                                    end: item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : item.duration)
            self.close()
            await Self.export(url, range: range)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }

    private func close() {
        (window?.contentView as? AVPlayerView)?.player?.pause()
        window?.close()
    }

    private static func export(_ url: URL, range: CMTimeRange) async {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return ShelfTools.failed("Couldn't trim this")
        }
        session.timeRange = range
        let target = ShelfStore.free(url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (trimmed)").appendingPathExtension(url.pathExtension))
        let type: AVFileType = switch url.pathExtension.lowercased() { case "mp4": .mp4; case "m4v": .m4v; case "m4a": .m4a; default: .mov }
        guard await session.write(to: target, as: type) else { return ShelfTools.failed("Couldn't trim this") }
        let seconds = Int(range.duration.seconds.rounded())
        ShelfTools.done([target], title: "Trimmed", detail: "\(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(target.lastPathComponent)")
    }
}

extension AVAssetExportSession {
    /// Exports and says whether a file came out (the async API on macOS 15, the callback before).
    @MainActor func write(to url: URL, as type: AVFileType) async -> Bool {
        if #available(macOS 15, *) {
            do { try await export(to: url, as: type) } catch { return false }
        } else {
            outputURL = url
            outputFileType = type
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                nonisolated(unsafe) let session = self
                session.exportAsynchronously { done.resume() }
            }
            guard status == .completed else { return false }
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
