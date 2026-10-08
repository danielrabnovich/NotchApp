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

    /// The loaded model, for the indexer and search on any thread.
    nonisolated static var model: CLIPModel? { lock.withLock { loaded } }
    nonisolated(unsafe) private static var loaded: CLIPModel?
    private nonisolated static let lock = NSLock()

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

    /// Loads the model if it's been downloaded before.
    func start() {
        guard isInstalled else { return }
        state = .preparing
        Task.detached(priority: .utility) {
            let result = Result { try CLIPModel(directory: Self.directory) }
            await self.finishLoading(result)
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
                let model = try await Task.detached(priority: .utility) { try CLIPModel(directory: Self.directory) }.value
                finishLoading(.success(model))
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
        Self.lock.withLock { Self.loaded = nil }
        try? FileManager.default.removeItem(at: Self.directory)
        ImageIndexStore.shared.removeVectors()
        state = .notInstalled
    }

    private func finishLoading(_ result: Result<CLIPModel, Error>) {
        switch result {
        case .success(let model):
            Self.lock.withLock { Self.loaded = model }
            state = .ready
            // The first text query pays for loading the encoder onto the Neural Engine; do it now.
            Task.detached(priority: .utility) { _ = try? model.embed(text: "a photo") }
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
