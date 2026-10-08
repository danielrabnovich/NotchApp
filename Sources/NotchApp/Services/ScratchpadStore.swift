import Foundation

/// A single free-form note, saved to Application Support shortly after each edit.
@MainActor
final class ScratchpadStore: ObservableObject {
    static let shared = ScratchpadStore()

    @Published var text = "" { didSet { scheduleSave() } }
    private var saveWork: DispatchWorkItem?
    private var loaded = false

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scratchpad.txt")
    }

    func load() {
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        loaded = true
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveWork?.cancel()
        let snapshot = text
        let target = url
        let work = DispatchWorkItem { try? snapshot.write(to: target, atomically: true, encoding: .utf8) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
