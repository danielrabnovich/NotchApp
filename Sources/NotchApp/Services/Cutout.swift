import AppKit
import CoreImage
import Vision

/// Lifts the subject out of photos (people, pets, objects) onto a transparent background, on this
/// Mac with Vision: "photo (cutout).png" beside each original.
@MainActor
enum Cutout {
    static func run(_ urls: [URL]) {
        NotchPresenter.shared.primary?.close()
        ActivityCenter.shared.show(.notice(title: "Removing background…", detail: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) images",
                                           icon: "person.crop.rectangle", tone: .info), for: 2)
        Task {
            var made: [URL] = []
            for url in urls {
                if let out = try? await Task.detached(priority: .userInitiated, operation: { try cutout(url) }).value { made.append(out) }
            }
            guard !made.isEmpty else {
                ActivityCenter.shared.show(.notice(title: "No subject found", detail: "Couldn't tell what to keep", icon: "person.crop.rectangle",
                                                   tone: .warning), for: 3)
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting(made)
            ActivityCenter.shared.show(.notice(title: made.count == 1 ? "Background removed" : "Removed \(made.count) backgrounds",
                                               detail: made.count == 1 ? made[0].lastPathComponent : "Saved beside the originals",
                                               icon: "checkmark.circle.fill", tone: .success), for: 3)
        }
    }

    private nonisolated static func cutout(_ url: URL) throws -> URL {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw CocoaError(.fileReadCorruptFile) }
        let handler = VNImageRequestHandler(ciImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw CocoaError(.featureUnsupported) }
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        let output = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: CIImage(cvPixelBuffer: mask),
        ])
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + " (cutout)"
        var out = folder.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = folder.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        try CIContext().writePNGRepresentation(of: output, to: out, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return out
    }
}
