import QuickLookThumbnailing
import SwiftUI

enum Thumbnail {
    static func load(_ url: URL, size: CGFloat) async -> NSImage? {
        await withCheckedContinuation { cont in
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                       scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
    }
}
