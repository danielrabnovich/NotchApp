import Foundation
import Security

/// Where the intelligence comes from: the local Ollama model, or a cloud model with your own key.
enum AIProvider: String, CaseIterable, Identifiable {
    case local, anthropic, deepseek, zai, customAnthropic, openai, openrouter, gemini, groq, custom

    var id: String { rawValue }

    enum Wire { case anthropic, openAI }

    /// Anthropic's Messages API, which DeepSeek and Z.ai also serve; the rest speak OpenAI's chat API.
    var wire: Wire { [.anthropic, .deepseek, .zai, .customAnthropic].contains(self) ? .anthropic : .openAI }

    var title: String {
        switch self {
        case .local: "On this Mac (Ollama)"
        case .anthropic: "Anthropic (Claude)"
        case .deepseek: "DeepSeek"
        case .zai: "Z.ai (GLM)"
        case .customAnthropic: "Other (Anthropic-compatible)"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .gemini: "Google Gemini"
        case .groq: "Groq"
        case .custom: "Other (OpenAI-compatible)"
        }
    }

    /// Short name for status lines ("Sent to Anthropic").
    var shortName: String {
        switch self {
        case .local: "this Mac"
        case .anthropic: "Anthropic"
        case .deepseek: "DeepSeek"
        case .zai: "Z.ai"
        case .customAnthropic: "your provider"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .gemini: "Google"
        case .groq: "Groq"
        case .custom: "your provider"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .local: ""
        case .anthropic: "https://api.anthropic.com/v1"
        case .deepseek: "https://api.deepseek.com/anthropic/v1"
        case .zai: "https://api.z.ai/api/anthropic/v1"
        case .customAnthropic: "https://api.example.com/anthropic/v1"
        case .openai: "https://api.openai.com/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .groq: "https://api.groq.com/openai/v1"
        case .custom: "http://localhost:1234/v1"
        }
    }

    /// Model picked before the list has been fetched. Only Anthropic's is filled in (its current
    /// default); the others come from the provider's own model list once the key is checked.
    var suggestedModel: String { self == .anthropic ? "claude-opus-5-5" : "" }

    /// Where the model list is when the Anthropic-style endpoint doesn't list them (OpenAI-style).
    var fallbackModelsURL: String? {
        switch self {
        case .deepseek: "https://api.deepseek.com/models"
        case .zai: "https://api.z.ai/api/paas/v4/models"
        default: nil
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .deepseek: "sk-…"
        case .openai: "sk-…"
        case .openrouter: "sk-or-…"
        case .gemini: "AIza…"
        case .groq: "gsk_…"
        default: "API key (optional for local servers)"
        }
    }

    var keyURL: URL? {
        switch self {
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")
        case .zai: URL(string: "https://z.ai/manage-apikey/apikey-list")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .openrouter: URL(string: "https://openrouter.ai/keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .groq: URL(string: "https://console.groq.com/keys")
        default: nil
        }
    }

    /// A local server (LM Studio and the like) may need no key.
    var keyRequired: Bool { self != .custom && self != .customAnthropic }

    /// Whether the server address is worth showing (the first-party ones never change).
    var editableServer: Bool { ![.anthropic, .openai, .local].contains(self) }
}

/// API keys, in the login Keychain (never in preferences).
enum APIKeys {
    private static let service = "com.notchapp.NotchApp.ai"

    static func get(_ provider: AIProvider) -> String? {
        var query = base(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func set(_ key: String?, for provider: AIProvider) {
        SecItemDelete(base(provider) as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var item = base(provider)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func base(_ provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }
}

/// Chat with a cloud model: Anthropic's Messages API, or any OpenAI-compatible endpoint (OpenAI,
/// OpenRouter, Gemini, Groq, LM Studio…). Every AI feature goes through `OllamaClient`, which
/// hands off to this when a cloud provider is chosen in Settings.
enum CloudLLM {
    struct Config: Sendable {
        let provider: AIProvider
        let key: String?
        let model: String
        let baseURL: URL
    }

    struct CloudError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The cloud model in use, or nil for the local one (or a cloud provider not set up yet).
    @MainActor static var active: Config? {
        let s = AppSettings.shared
        guard s.aiProvider != .local else { return nil }
        return config(for: s.aiProvider)
    }

    @MainActor static func config(for provider: AIProvider) -> Config? {
        let s = AppSettings.shared
        let key = APIKeys.get(provider)
        let model = s.cloudModel(for: provider)
        guard !model.isEmpty, key != nil || !provider.keyRequired,
              let url = URL(string: s.cloudBaseURL(for: provider)) else { return nil }
        return Config(provider: provider, key: key, model: model, baseURL: url)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    // MARK: - Chat

    /// One reply. `json` asks for a bare JSON object; `quick` marks short structured calls (routing,
    /// planning) that should spend little effort.
    static func chat(_ c: Config, system: String, user: String, images: [Data], json: Bool, quick: Bool) async throws -> String {
        try await stream(c, system: system, user: user, images: images, json: json, quick: quick) { _ in }
    }

    /// Streams the reply, calling `onText` with the full text so far; returns the final text.
    @discardableResult
    static func stream(_ c: Config, system: String, user: String, images: [Data], json: Bool = false, quick: Bool = false,
                       onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        do {
            return try await run(c, system: system, user: user, images: images, json: json, quick: quick, onText: onText)
        } catch let error as CloudError where !images.isEmpty && error.message.localizedCaseInsensitiveContains("image") {
            // A model that can't take pictures: ask again with the text alone.
            return try await run(c, system: system, user: user, images: [], json: json, quick: quick, onText: onText)
        }
    }

    private static func run(_ c: Config, system: String, user: String, images: [Data], json: Bool, quick: Bool,
                            onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        let request = try c.provider.wire == .anthropic
            ? anthropicRequest(c, system: system, user: user, images: images, json: json, quick: quick)
            : openAIRequest(c, system: system, user: user, images: images, json: json)
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 4000 { break } }
            throw CloudError(message: errorMessage(body, status: http.statusCode, provider: c.provider))
        }
        var text = ""
        var refused = false
        var lastEmit = Date.distantPast
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if c.provider.wire == .anthropic {
                switch obj["type"] as? String {
                case "content_block_delta":
                    let delta = obj["delta"] as? [String: Any]
                    if delta?["type"] as? String == "text_delta", let t = delta?["text"] as? String { text += t }
                case "message_delta":
                    if (obj["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" { refused = true }
                case "error":
                    let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "The model stopped with an error."
                    throw CloudError(message: message)
                default:
                    break
                }
            } else {
                if let error = obj["error"] as? [String: Any] {
                    throw CloudError(message: error["message"] as? String ?? "The model stopped with an error.")
                }
                let choice = (obj["choices"] as? [[String: Any]])?.first
                if let t = (choice?["delta"] as? [String: Any])?["content"] as? String { text += t }
            }
            if Date().timeIntervalSince(lastEmit) > 0.05 {
                lastEmit = Date()
                await onText(text)
            }
        }
        // A declined request (after any fallback model also declined): don't show half an answer.
        if refused { throw CloudError(message: "The model declined to answer that.") }
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        await onText(final)
        return final
    }

    // MARK: - Requests

    private static func anthropicRequest(_ c: Config, system: String, user: String, images: [Data], json: Bool,
                                         quick: Bool) throws -> URLRequest {
        var content: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
        }
        content.append(["type": "text", "text": user])
        var body: [String: Any] = [
            "model": c.model,
            "max_tokens": 16000,
            "stream": true,
            "messages": [["role": "user", "content": content]],
        ]
        let instructions = json ? system + "\nReply with ONLY the JSON object: no prose, no code fences." : system
        if !instructions.isEmpty { body["system"] = instructions }
        // Effort: little for routing and planning (they gate everything after them), the model's
        // default for answers. Only on models that take the setting.
        if supportsEffort(c.model) { body["output_config"] = ["effort": quick || json ? "low" : "medium"] }
        var request = URLRequest(url: c.baseURL.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        authorize(&request, c)
        // On models whose safety classifiers can decline, let Anthropic re-run a declined request
        // on its recommended fallback model instead of returning the refusal.
        if usesDefaultFallback(c.model) {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func openAIRequest(_ c: Config, system: String, user: String, images: [Data], json: Bool) throws -> URLRequest {
        let userContent: Any
        if images.isEmpty {
            userContent = user
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": user]]
            parts += images.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]] }
            userContent = parts
        }
        let instructions = json ? system + "\nReply with ONLY the JSON object: no prose, no code fences." : system
        var messages: [[String: Any]] = []
        if !instructions.isEmpty { messages.append(["role": "system", "content": instructions]) }
        messages.append(["role": "user", "content": userContent])
        let body: [String: Any] = ["model": c.model, "stream": true, "messages": messages]
        var request = URLRequest(url: c.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = c.key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if c.provider == .openrouter {
            request.setValue("https://github.com/notchapp", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("NotchApp", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Anthropic takes the key as x-api-key; Anthropic-compatible services (DeepSeek, Z.ai…) also
    /// accept it as a bearer token, which some of them require.
    private static func authorize(_ request: inout URLRequest, _ c: Config) {
        guard let key = c.key else { return }
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        if c.provider != .anthropic { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    }

    /// Current Claude models take `output_config.effort`; Haiku 4.5, Sonnet 4.5 and older reject it.
    static func supportsEffort(_ model: String) -> Bool {
        ["claude-fable-", "claude-mythos-", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
         "claude-opus-4-5", "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-5"].contains { model.hasPrefix($0) }
    }

    /// Models that accept `fallbacks: "default"` on the Claude API.
    static func usesDefaultFallback(_ model: String) -> Bool {
        ["claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
    }

    private static func errorMessage(_ body: String, status: Int, provider: AIProvider) -> String {
        let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        let message = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? (obj?["message"] as? String)
        switch status {
        case 401, 403: return "\(provider.shortName) didn't accept the API key. Check it in Settings → Search."
        case 404: return message ?? "\(provider.shortName) doesn't know that model. Pick another in Settings → Search."
        case 429: return "\(provider.shortName) is rate-limiting requests. Try again in a moment."
        default: return message ?? "\(provider.shortName) returned an error (\(status))."
        }
    }

    // MARK: - Models

    struct ModelInfo: Identifiable, Hashable, Sendable {
        let id: String
        /// A friendlier name, when the provider gives one ("Claude Opus 5.5").
        var name: String?
    }

    /// The models this key can use (checks the key too). For Anthropic-style services that don't
    /// list models there, their OpenAI-style list.
    static func models(_ c: Config) async throws -> [ModelInfo] {
        do {
            return try await listModels(c, url: c.baseURL.appendingPathComponent("models"), anthropicStyle: c.provider.wire == .anthropic)
        } catch {
            guard let fallback = c.provider.fallbackModelsURL.flatMap(URL.init(string:)) else { throw error }
            return try await listModels(c, url: fallback, anthropicStyle: false)
        }
    }

    private static func listModels(_ c: Config, url: URL, anthropicStyle: Bool) async throws -> [ModelInfo] {
        var request = URLRequest(url: anthropicStyle ? URL(string: url.absoluteString + "?limit=100") ?? url : url)
        request.timeoutInterval = 15
        if anthropicStyle {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            authorize(&request, c)
        } else if let key = c.key {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw CloudError(message: errorMessage(String(decoding: data, as: UTF8.self), status: http.statusCode, provider: c.provider))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]], !list.isEmpty else {
            throw CloudError(message: "\(c.provider.shortName) didn't list any models.")
        }
        // Gemini lists "models/gemini-…"; the chat endpoint wants the bare name.
        return list.compactMap { m -> ModelInfo? in
            guard var id = m["id"] as? String else { return nil }
            if id.hasPrefix("models/") { id.removeFirst(7) }
            let name = (m["display_name"] ?? m["name"]) as? String
            return ModelInfo(id: id, name: name == id ? nil : name)
        }
    }
}
