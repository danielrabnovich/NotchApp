import AppKit
import Combine
import SwiftUI

/// Recent finished downloads from ~/Downloads, newest first, with a heads-up when one lands.
@MainActor
final class DownloadsStore: ObservableObject {
    static let shared = DownloadsStore()

    @Published private(set) var items: [ShelfItem] = []

    let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<URL> = []
    private var rescanWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    /// Browsers write to these first and rename once the download completes.
    nonisolated private static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp"]

    func start() {
        AppSettings.shared.$downloadsEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                DispatchQueue.main.async { enabled ? self?.begin() : self?.end() }
            }
            .store(in: &cancellables)
    }

    private var opening = false

    private func begin() {
        guard source == nil, !opening else { return }
        opening = true
        let path = folder.path
        // Opening ~/Downloads can block until the user answers macOS's folder-access prompt,
        // so never do it on the main thread (it froze the whole notch).
        DispatchQueue.global(qos: .utility).async {
            let fd = open(path, O_EVTONLY)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = DownloadsStore.shared
                    me.opening = false
                    guard fd >= 0 else { return }
                    guard AppSettings.shared.downloadsEnabled, me.source == nil else { close(fd); return }
                    let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
                    s.setEventHandler { MainActor.assumeIsolated { DownloadsStore.shared.scheduleRescan() } }
                    s.setCancelHandler { close(fd) }
                    s.resume()
                    me.source = s
                    me.rescan(initial: true)
                }
            }
        }
    }

    private func end() {
        source?.cancel()
        source = nil
        items = []
        known = []
    }

    func moveToTrash(_ item: ShelfItem) {
        NSWorkspace.shared.recycle([item.url]) { _, _ in }
    }

    private func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan(initial: false) }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func rescan(initial: Bool) {
        let folder = folder
        // Directory reads happen off the main thread; only the results are applied here.
        DispatchQueue.global(qos: .utility).async {
            let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                          options: [.skipsHiddenFiles]) else { return }
            let finished = urls.filter { !Self.partialExtensions.contains($0.pathExtension.lowercased()) }
            let dated = finished.map { url -> (URL, Date) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast)
            }
            let recent = Array(dated.sorted { $0.1 > $1.1 }.prefix(24).map(\.0))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DownloadsStore.shared.apply(recent: recent, finished: finished, initial: initial) }
            }
        }
    }

    private func apply(recent: [URL], finished: [URL], initial: Bool) {
        let existing = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            items = recent.map { existing[$0] ?? ShelfItem(url: $0) }
        }

        let fresh = recent.filter { !known.contains($0) }
        known = Set(finished)
        if !initial, let newest = fresh.first, AppSettings.shared.downloadAlerts {
            ActivityCenter.shared.show(.download(name: newest.lastPathComponent), for: 3.5)
        }
    }
}
