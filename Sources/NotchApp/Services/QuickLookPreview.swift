import AppKit
import Quartz

/// Quick Look for files on the shelf (and anywhere else): the system's own preview panel, with
/// the arrow keys moving between the files.
@MainActor
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreview()
    private var urls: [URL] = []

    func show(_ urls: [URL], at index: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        // The notch never becomes the active app; the panel needs it to take the arrow keys and Esc.
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(index, urls.count - 1)
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
