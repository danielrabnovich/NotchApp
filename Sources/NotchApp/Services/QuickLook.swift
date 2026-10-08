import AppKit
import Quartz

/// Quick Look for search results (⌘Y), like Finder's. The panel is shown without taking keyboard
/// focus, so the search bar keeps the arrow keys and the preview follows the selection.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()

    private var urls: [URL] = []
    /// Arrow keys pressed while the preview has the keyboard, passed back to the search bar.
    var onMove: ((Int) -> Void)?

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle(_ urls: [URL], at index: Int) {
        if isVisible { close() } else { show(urls, at: index) }
    }

    func show(_ urls: [URL], at index: Int) {
        guard urls.indices.contains(index), let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        let searchWindow = NSApp.keyWindow
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = index
        // Above the notch, which sits just over the menu bar.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.orderFront(nil)
        // Quick Look takes the keyboard when it appears; give it back so typing and the arrow keys
        // keep going to the search bar.
        searchWindow?.makeKey()
    }

    /// Moves an open preview to the newly selected result.
    func follow(_ urls: [URL], at index: Int) {
        guard isVisible, urls.indices.contains(index), let panel = QLPreviewPanel.shared() else { return }
        if urls != self.urls {
            self.urls = urls
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
        }
        panel.currentPreviewItemIndex = index
    }

    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let delta: Int? = switch event.keyCode {
        case 125: 1   // down
        case 126: -1  // up
        default: nil
        }
        guard let delta else { return false }
        MainActor.assumeIsolated { onMove?(delta) }
        return true
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}
