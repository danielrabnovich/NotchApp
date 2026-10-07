import Foundation

/// Minimal client for a local Ollama server (https://ollama.com).
enum OllamaClient {
    enum Status: Equatable {
        case unknown, notRunning, modelMissing(String), ready
    }

    struct OllamaError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
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

    // MARK: - Status

    static func installedModels() async throws -> [String] {
        let url = await baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, _) = try await session.data(for: request)
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
    }

    static func status() async -> Status {
        let wanted = await model
        guard let models = try? await installedModels() else { return .notRunning }
        let matches = models.contains { $0 == wanted || $0 == wanted + ":latest" || $0.hasPrefix(wanted + ":") && !wanted.contains(":") }
        return matches ? .ready : .modelMissing(wanted)
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

    /// Downloads a model, reporting progress 0...1.
    static func pull(_ name: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: await baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
        let (bytes, _) = try await session.bytes(for: request)
        for try await line in bytes.lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = obj["error"] as? String { throw OllamaError(message: error) }
            if let total = obj["total"] as? Double, let done = obj["completed"] as? Double, total > 0 {
                progress(done / total)
            }
        }
    }

    // MARK: - Chat

    /// Single-shot chat. With `json: true` the model is constrained to emit a JSON object.
    static func chat(system: String, user: String, json: Bool = false, temperature: Double = 0.2) async throws -> String {
        var body: [String: Any] = [
            "model": await model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": false,
            "think": false,
            "keep_alive": "15m",
            "options": ["temperature": temperature, "num_ctx": 16384],
        ]
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
        let body: [String: Any] = [
            "model": await model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": true,
            "think": false,
            "keep_alive": "15m",
            "options": ["temperature": temperature, "num_ctx": 16384],
        ]
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
