import Foundation

/// Minimal client for a local Ollama server (https://ollama.com).
enum OllamaClient {
    enum Status: Equatable {
        case unknown, notRunning, modelMissing(String), ready
    }

    struct OllamaError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        var isThinkingUnsupported: Bool { message.localizedCaseInsensitiveContains("does not support thinking") }
    }

    @MainActor static var baseURL: URL {
        URL(string: AppSettings.shared.ollamaURL) ?? URL(string: "http://localhost:11434")!
    }

    @MainActor static var model: String { AppSettings.shared.ollamaModel }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// Model downloads are several GB, so they get no overall time limit; only a stalled
    /// connection (no data for a minute) fails them.
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: config)
    }()

    // MARK: - Status

    struct InstalledModel: Identifiable, Equatable, Decodable {
        let name: String
        /// Bytes on disk.
        let size: Int64
        var id: String { name }
    }

    static func installedModelDetails() async throws -> [InstalledModel] {
        let url = await baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, _) = try await session.data(for: request)
        struct Tags: Decodable { let models: [InstalledModel] }
        return try JSONDecoder().decode(Tags.self, from: data).models
    }

    static func installedModels() async throws -> [String] {
        try await installedModelDetails().map(\.name)
    }

    /// Whether an installed tag satisfies a requested name ("llama3.2" matches "llama3.2:latest").
    static func matches(installed: String, wanted: String) -> Bool {
        installed == wanted || installed == wanted + ":latest" || (!wanted.contains(":") && installed.hasPrefix(wanted + ":"))
    }

    static func status() async -> Status {
        let wanted = await model
        guard let models = try? await installedModels() else { return .notRunning }
        return models.contains { matches(installed: $0, wanted: wanted) } ? .ready : .modelMissing(wanted)
    }

    static func delete(_ name: String) async throws {
        var request = URLRequest(url: await baseURL.appendingPathComponent("api/delete"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name])
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OllamaError(message: message ?? "Couldn't delete \(name)")
        }
    }

    /// Whether Ollama is installed (CLI or desktop app), so the UI can offer to start it.
    static var isInstalled: Bool {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Starts the Homebrew-installed server if it isn't running.
    static func startServer() {
        for brew in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] where FileManager.default.fileExists(atPath: brew) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: brew)
            p.arguments = ["services", "start", "ollama"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            return
        }
        // Fall back to the desktop app if that's how Ollama was installed.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Ollama"]
        try? p.run()
    }

    /// Where a model download is up to.
    struct PullProgress: Equatable, Sendable {
        enum Phase: Equatable, Sendable { case lookingUp, downloading, verifying, finishing }
        var phase: Phase = .lookingUp
        /// Bytes across every layer of the model.
        var completed: Int64 = 0
        var total: Int64 = 0
        var fraction: Double? { total > 0 ? min(1, Double(completed) / Double(total)) : nil }
    }

    /// Normalises what people type or paste: "ollama pull Qwen3.5:9B" → "qwen3.5:9b".
    static func cleanModelName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["ollama pull ", "ollama run "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if let r = s.range(of: "ollama.com/library/") { s = String(s[r.upperBound...]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a name looks like an Ollama model reference (letters, digits, . _ - / and one tag).
    static func isPlausibleModelName(_ s: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/:"))
        return !s.isEmpty && s.unicodeScalars.allSatisfy(allowed.contains) && s.filter { $0 == ":" }.count <= 1
            && !s.hasPrefix(":") && !s.hasSuffix(":")
    }

    /// Downloads a model. Ollama streams one status line per layer; this totals the layers.
    static func pull(_ name: String, progress: @escaping @Sendable (PullProgress) -> Void) async throws {
        var request = URLRequest(url: await baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
        let bytes: URLSession.AsyncBytes
        do {
            (bytes, _) = try await downloadSession.bytes(for: request)
        } catch {
            throw OllamaError(message: "Couldn't reach Ollama. Is it running?")
        }
        var layers: [String: (completed: Int64, total: Int64)] = [:]
        var state = PullProgress()
        progress(state)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = obj["error"] as? String {
                throw OllamaError(message: error.contains("file does not exist") || error.contains("not found")
                                  ? "“\(name)” wasn't found in the Ollama library. Check the spelling and tag on ollama.com/library."
                                  : error)
            }
            let status = obj["status"] as? String ?? ""
            if let digest = obj["digest"] as? String, let total = (obj["total"] as? NSNumber)?.int64Value, total > 0 {
                layers[digest] = ((obj["completed"] as? NSNumber)?.int64Value ?? 0, total)
                state.phase = .downloading
            } else if status.hasPrefix("verifying") {
                state.phase = .verifying
            } else if status.hasPrefix("writing") || status == "success" {
                state.phase = .finishing
            }
            state.completed = layers.values.reduce(0) { $0 + $1.completed }
            state.total = layers.values.reduce(0) { $0 + $1.total }
            progress(state)
        }
    }

    // MARK: - Chat

    /// Single-shot chat. With `json: true` the model is constrained to emit a JSON object.
    static func chat(system: String, user: String, json: Bool = false, temperature: Double = 0.2) async throws -> String {
        do {
            return try await chat(system: system, user: user, json: json, temperature: temperature, disableThinking: true)
        } catch let error as OllamaError where error.isThinkingUnsupported {
            return try await chat(system: system, user: user, json: json, temperature: temperature, disableThinking: false)
        }
    }

    /// `disableThinking` sends "think": false so thinking models answer directly; models without
    /// a thinking mode can reject that option, so callers retry without it.
    private static func chat(system: String, user: String, json: Bool, temperature: Double, disableThinking: Bool) async throws -> String {
        var body: [String: Any] = [
            "model": await model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": false,
            "keep_alive": "15m",
            "options": ["temperature": temperature, "num_ctx": 16384],
        ]
        if disableThinking { body["think"] = false }
        if json { body["format"] = "json" }

        var request = URLRequest(url: await baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw OllamaError(message: "Couldn't reach Ollama. Is it running?")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OllamaError(message: "Unexpected response from Ollama")
        }
        if let error = obj["error"] as? String { throw OllamaError(message: error) }
        let content = (obj["message"] as? [String: Any])?["content"] as? String ?? ""
        return stripThinking(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streams the reply, calling `onText` with the full text so far.
    static func chatStream(system: String, user: String, temperature: Double = 0.3,
                           onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        do {
            return try await chatStream(system: system, user: user, temperature: temperature, disableThinking: true, onText: onText)
        } catch let error as OllamaError where error.isThinkingUnsupported {
            return try await chatStream(system: system, user: user, temperature: temperature, disableThinking: false, onText: onText)
        }
    }

    private static func chatStream(system: String, user: String, temperature: Double, disableThinking: Bool,
                                   onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        var body: [String: Any] = [
            "model": await model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": true,
            "keep_alive": "15m",
            "options": ["temperature": temperature, "num_ctx": 16384],
        ]
        if disableThinking { body["think"] = false }
        var request = URLRequest(url: await baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, _) = try await session.bytes(for: request)
        var text = ""
        var lastEmit = Date.distantPast
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = obj["error"] as? String { throw OllamaError(message: error) }
            text += ((obj["message"] as? [String: Any])?["content"] as? String) ?? ""
            if Date().timeIntervalSince(lastEmit) > 0.05 {
                lastEmit = Date()
                await onText(stripThinking(text))
            }
        }
        let final = stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        await onText(final)
        return final
    }

    static func chatJSON(system: String, user: String) async throws -> [String: Any] {
        let text = try await chat(system: system, user: user, json: true, temperature: 0.1)
        if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return obj }
        // Models occasionally wrap JSON in prose; grab the outermost object.
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
           let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] {
            return obj
        }
        throw OllamaError(message: "The model didn't return valid JSON")
    }

    private static func stripThinking(_ s: String) -> String {
        guard let r = s.range(of: "</think>") else { return s }
        return String(s[r.upperBound...])
    }
}
