import CoreML
import Foundation

/// The optional MobileCLIP download that lets picture search understand descriptions
/// ("lighthouse at dusk") rather than only Vision's fixed labels. Downloaded once (~110 MB) from
/// Apple's Core ML release on Hugging Face, compiled on this Mac and kept in Application Support.
@MainActor
final class VisualSearch: ObservableObject {
    static let shared = VisualSearch()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    /// The model, for the indexer and search on any thread. It's loaded on first use and let go
    /// after a couple of idle minutes: both encoders plus the tokenizer's tables are well over
    /// 100 MB, and kept for good they were the biggest part of the app's memory. Nil when it isn't
    /// installed. The first call after a while blocks while it loads (well under a second).
    nonisolated static var model: CLIPModel? {
        lock.withLock {
            guard usable else { return nil }
            if loaded == nil {
                do { loaded = try CLIPModel(directory: directory) } catch { DebugHooks.log("VisualSearch load failed: \(error)") }
            }
            lastUse = Date()
            if loaded != nil, !unloadScheduled { scheduleUnload() }
            return loaded
        }
    }

    /// Whether the model is installed and loads (no loading involved). Set on the main actor.
    nonisolated static var isUsable: Bool { lock.withLock { usable } }

    /// Loads the model ahead of a search that may need it, off the main thread.
    nonisolated static func prewarm() {
        guard isUsable, lock.withLock({ loaded == nil }) else { return }
        DispatchQueue.global(qos: .userInitiated).async { _ = model }
    }

    nonisolated(unsafe) private static var loaded: CLIPModel?
    nonisolated(unsafe) private static var usable = false
    nonisolated(unsafe) private static var lastUse = Date.distantPast
    nonisolated(unsafe) private static var unloadScheduled = false
    private nonisolated static let lock = NSLock()
    private nonisolated static let idleLimit: TimeInterval = 120

    /// Called with the lock held.
    private nonisolated static func scheduleUnload() {
        unloadScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleLimit) {
            lock.withLock {
                unloadScheduled = false
                if Date().timeIntervalSince(lastUse) >= idleLimit {
                    loaded = nil
                } else if loaded != nil {
                    scheduleUnload()
                }
            }
        }
    }

    private var task: Task<Void, Never>?

    nonisolated static let directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchApp/MobileCLIP", isDirectory: true)

    private static let modelBase = "https://huggingface.co/apple/coreml-mobileclip/resolve/main"
    private static let tokenizerBase = "https://raw.githubusercontent.com/apple/ml-mobileclip/main/ios_app/MobileCLIPExplore/Resources"
    /// Each file with its size, so progress moves smoothly across the whole download.
    private static let downloads: [(path: String, url: String, bytes: Int64)] = {
        var list: [(String, String, Int64)] = []
        for (name, weights) in [("mobileclip_s0_image", Int64(22_717_696)), ("mobileclip_s0_text", 84_871_616)] {
            for (file, bytes) in [("Manifest.json", Int64(617)), ("Data/com.apple.CoreML/model.mlmodel", 150_000),
                                  ("Data/com.apple.CoreML/weights/weight.bin", weights)] {
                list.append(("\(name).mlpackage/\(file)", "\(modelBase)/\(name).mlpackage/\(file)", bytes))
            }
        }
        list.append(("clip-vocab.json", "\(tokenizerBase)/clip-vocab.json", 1_197_317))
        list.append(("clip-merges.txt", "\(tokenizerBase)/clip-merges.txt", 3_194_958))
        return list
    }()

    var isInstalled: Bool { CLIPModel.files.allSatisfy { FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent($0).path) } }

    /// Checks the model downloaded before still loads (then lets it go until a search needs it).
    func start() {
        guard isInstalled else { return }
        state = .preparing
        Task.detached(priority: .utility) {
            let result = Result { try CLIPModel(directory: Self.directory) }
            await self.finishLoading(result.map { _ in () })
        }
    }

    func install() {
        guard task == nil, state != .ready else { return }
        state = .downloading(0)
        task = Task {
            do {
                try await download()
                state = .preparing
                try await compile()
                _ = try await Task.detached(priority: .utility) { try CLIPModel(directory: Self.directory) }.value
                finishLoading(.success(()))
            } catch {
                state = Task.isCancelled ? .notInstalled : .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    func remove() {
        task?.cancel()
        Self.lock.withLock { Self.loaded = nil; Self.usable = false }
        try? FileManager.default.removeItem(at: Self.directory)
        ImageIndexStore.shared.removeVectors()
        state = .notInstalled
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            Self.lock.withLock { Self.usable = true }
            state = .ready
            // Pictures indexed before the model was here get their vectors on the next pass.
            ImageIndex.shared.refresh()
        case .failure(let error):
            DebugHooks.log("VisualSearch load failed: \(error)")
            state = .failed("Couldn't load the model. Remove it and download again.")
        }
    }

    // MARK: - Install

    private var staging: URL { Self.directory.deletingLastPathComponent().appendingPathComponent("MobileCLIP-download", isDirectory: true) }

    private func download() async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        let total = Self.downloads.reduce(0) { $0 + $1.bytes }
        var done: Int64 = 0
        for file in Self.downloads {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            try await Self.fetch(URL(string: file.url)!, to: target) { [weak self] fraction in
                Task { @MainActor in self?.state = .downloading(Double(base + Int64(Double(file.bytes) * fraction)) / Double(total)) }
            }
            done += file.bytes
        }
    }

    /// Compiles both packages for this Mac and moves everything into place.
    private func compile() async throws {
        let fm = FileManager.default
        let staging = staging
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for name in ["mobileclip_s0_image", "mobileclip_s0_text"] {
            let compiled = try await MLModel.compileModel(at: staging.appendingPathComponent("\(name).mlpackage"))
            let target = Self.directory.appendingPathComponent("\(name).mlmodelc")
            try? fm.removeItem(at: target)
            try fm.moveItem(at: compiled, to: target)
        }
        for name in ["clip-vocab.json", "clip-merges.txt"] {
            let target = Self.directory.appendingPathComponent(name)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: staging.appendingPathComponent(name), to: target)
        }
        try? fm.removeItem(at: staging)
    }

    /// Downloads one file, reporting how much of it has arrived.
    private nonisolated static func fetch(_ url: URL, to target: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                    if let error { return continuation.resume(throwing: error) }
                    guard let temp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                        return continuation.resume(throwing: URLError(.badServerResponse))
                    }
                    do {
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.moveItem(at: temp, to: target)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
    }
}
