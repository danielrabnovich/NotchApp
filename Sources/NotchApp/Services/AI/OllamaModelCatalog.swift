import Foundation

/// Suggested models for the Ask tab. Any other model from ollama.com/library can be downloaded by name.
enum OllamaModelCatalog {
    struct Entry: Identifiable {
        let name: String
        let title: String
        /// Approximate download size, as listed on ollama.com.
        let size: String
        let blurb: String
        var id: String { name }
    }

    static let defaultModel = "qwen3.5:9b"

    /// The newest laptop-sized model from each of Alibaba, Google and Meta. (Qwen 3.6/3.8 only
    /// come in 27B+ and Llama 4 starts at 67 GB, so the newest smaller releases are listed.)
    static let recommended: [Entry] = [
        Entry(name: "qwen3.5:9b", title: "Qwen 3.5", size: "~7 GB", blurb: "Alibaba · best all-rounder"),
        Entry(name: "gemma4:e4b", title: "Gemma 4", size: "~7–10 GB", blurb: "Google · strong reasoning"),
        Entry(name: "llama3.2:3b", title: "Llama 3.2", size: "2 GB", blurb: "Meta · small and fast"),
    ]

    static func entry(named name: String) -> Entry? {
        recommended.first { OllamaClient.matches(installed: $0.name, wanted: name) }
    }

    static func displayName(_ name: String) -> String { entry(named: name)?.title ?? name }
}
