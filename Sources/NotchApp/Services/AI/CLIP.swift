import Accelerate
import CoreML
import Foundation
import Vision

/// Apple's MobileCLIP-S0 (github.com/apple/ml-mobileclip): turns pictures and sentences into
/// vectors in the same space, so "red car in the snow" can be compared with every indexed image.
/// The two Core ML encoders and the tokenizer files are downloaded once into `directory`.
final class CLIPModel: @unchecked Sendable {
    static let files = ["mobileclip_s0_image.mlmodelc", "mobileclip_s0_text.mlmodelc", "clip-vocab.json", "clip-merges.txt"]

    private let imageEncoder: MLModel
    private let textEncoder: MLModel
    private let tokenizer: CLIPTokenizer
    /// Core ML models aren't guaranteed to be safe to call from several threads at once.
    private let lock = NSLock()

    init(directory: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        imageEncoder = try MLModel(contentsOf: directory.appendingPathComponent(Self.files[0]), configuration: config)
        textEncoder = try MLModel(contentsOf: directory.appendingPathComponent(Self.files[1]), configuration: config)
        tokenizer = try CLIPTokenizer(vocab: directory.appendingPathComponent(Self.files[2]),
                                      merges: directory.appendingPathComponent(Self.files[3]))
    }

    /// A unit-length vector for a picture (center-cropped to the model's 256×256).
    func embed(image: CGImage) throws -> [Float] {
        let input = try MLFeatureValue(cgImage: image, constraint: imageConstraint,
                                       options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue])
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": input])
        return try lock.withLock { try Self.vector(imageEncoder.prediction(from: provider)) }
    }

    /// A unit-length vector for a sentence.
    func embed(text: String) throws -> [Float] {
        let ids = tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32)
        for (i, id) in ids.enumerated() { array[i] = NSNumber(value: id) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["text": array])
        return try lock.withLock { try Self.vector(textEncoder.prediction(from: provider)) }
    }

    /// Cosine similarity of two unit-length vectors.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        return vDSP.dot(a, b)
    }

    private var imageConstraint: MLImageConstraint {
        imageEncoder.modelDescription.inputDescriptionsByName["image"]!.imageConstraint!
    }

    private static func vector(_ output: MLFeatureProvider) throws -> [Float] {
        guard let array = output.featureValue(for: "final_emb_1")?.multiArrayValue else {
            throw CocoaError(.coderReadCorrupt)
        }
        let values = (0..<array.count).map { array[$0].floatValue }
        let norm = sqrt(vDSP.sumOfSquares(values))
        return norm > 0 ? vDSP.divide(values, norm) : values
    }
}

/// CLIP's byte-pair tokenizer, after the MIT-licensed Swift port in Apple's MobileCLIP demo app
/// (itself from Hugging Face's swift-coreml-transformers).
final class CLIPTokenizer: @unchecked Sendable {
    static let contextLength = 77

    private let encoder: [String: Int]
    private let ranks: [Pair: Int]
    private var cache: [String: [String]] = [:]
    private let lock = NSLock()

    private struct Pair: Hashable {
        let a: String
        let b: String
    }

    /// GPT-2's map from bytes to printable characters, so BPE never sees whitespace or control bytes.
    private static let byteEncoder: [UInt8: String] = {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var chars = bytes
        var extra = 0
        for b in 0..<256 where !bytes.contains(b) {
            bytes.append(b)
            chars.append(256 + extra)
            extra += 1
        }
        return Dictionary(uniqueKeysWithValues: zip(bytes, chars).map { (UInt8($0), String(UnicodeScalar(UInt32($1))!)) })
    }()

    private static let pattern = try! NSRegularExpression(
        pattern: "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+")

    init(vocab: URL, merges: URL) throws {
        encoder = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocab))
        let lines = try String(contentsOf: merges, encoding: .utf8).split(separator: "\n").dropFirst()
        var ranks: [Pair: Int] = [:]
        for (i, line) in lines.enumerated() {
            let parts = line.split(separator: " ")
            if parts.count == 2 { ranks[Pair(a: String(parts[0]), b: String(parts[1]))] = i }
        }
        self.ranks = ranks
    }

    /// Start token, the text's tokens (cut to fit), end token, then zeros up to 77.
    func encode(_ text: String) -> [Int] {
        let cleaned = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        var ids: [Int] = []
        for match in Self.pattern.matches(in: cleaned, range: range) {
            guard let r = Range(match.range, in: cleaned) else { continue }
            let word = cleaned[r].utf8.map { Self.byteEncoder[$0]! }.joined()
            ids += bpe(word).compactMap { encoder[$0] }
        }
        let start = encoder["<|startoftext|>"]!, end = encoder["<|endoftext|>"]!
        let body = Array(ids.prefix(Self.contextLength - 2))
        return [start] + body + [end] + Array(repeating: 0, count: Self.contextLength - body.count - 2)
    }

    /// Merges the word's characters pair by pair, lowest-ranked merge first.
    private func bpe(_ token: String) -> [String] {
        if let cached = lock.withLock({ cache[token] }) { return cached }
        var word = token.map(String.init)
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(word.count - 1) {
                if let rank = ranks[Pair(a: word[i], b: word[i + 1])], rank < best?.rank ?? .max { best = (rank, i) }
            }
            guard let best else { break }
            let first = word[best.index], second = word[best.index + 1]
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == first, word[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        lock.withLock { cache[token] = word }
        return word
    }
}
