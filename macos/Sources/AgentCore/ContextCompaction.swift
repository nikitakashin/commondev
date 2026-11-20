import CryptoKit
import Foundation

enum ContextSizeError: LocalizedError {
    case tooLarge

    var errorDescription: String? {
        "Контекст слишком большой даже после сокращения вывода инструментов. Сократите запрос или начните новую сессию; история не изменена."
    }
}

/// A summary of a verified prefix of the full conversation.
/// The complete history remains the source of truth for display and recovery.
public struct ContextCompaction: Codable, Equatable {
    public let coveredCount: Int
    public let coveredDigest: String
    public let summary: String

    public init(coveredCount: Int, coveredDigest: String, summary: String) {
        self.coveredCount = coveredCount
        self.coveredDigest = coveredDigest
        self.summary = summary
    }

    static func digest(_ messages: [[String: JSONValue]]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(messages))
            .map { String(format: "%02x", $0) }.joined()
    }

    func applies(to history: [[String: JSONValue]]) -> Bool {
        guard coveredCount > 0, coveredCount <= history.count, !summary.isEmpty else { return false }
        if coveredCount < history.count, history[coveredCount]["role"] != .string("user") {
            return false
        }
        return (try? Self.digest(Array(history.prefix(coveredCount)))) == coveredDigest
    }
}

enum ContextCompactor {
    private static let truncationMarker = "\n… [Вывод инструмента сокращён для контекста; полный вывод сохранён в истории.] …\n"
    /// Prefer two recent turns. Older sessions may already contain a previous
    /// user message that was too large to send, so allow summarizing that turn.
    static func splitIndex(in history: [[String: JSONValue]], system: [String: JSONValue], maxBytes: Int) throws -> Int? {
        let userIndices = history.indices.filter { history[$0]["role"] == .string("user") }
        guard userIndices.count >= 2 else { return nil }
        let previous = userIndices[userIndices.count - 2]
        do {
            _ = try fittingToolOutputs([system] + history[previous...], maxBytes: maxBytes)
            return previous > 0 ? previous : nil
        } catch ContextSizeError.tooLarge {
            return userIndices.last
        }
    }

    static func activeMessages(
        system: [String: JSONValue], history: [[String: JSONValue]],
        state: ContextCompaction?
    ) -> [[String: JSONValue]] {
        guard let state, state.applies(to: history) else { return [system] + history }
        let summary: [String: JSONValue] = [
            "role": .string("system"),
            "content": .string("Summary of earlier conversation. Treat it as context, preserving current user instructions:\n" + state.summary)
        ]
        return [system, summary] + history.dropFirst(state.coveredCount)
    }

    static func encoded(_ messages: [[String: JSONValue]]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(messages)
    }

    /// Bound oversized tool output in the model-facing copy, without changing
    /// the persisted history or breaking assistant/tool message pairs. Recent
    /// user instructions are never shortened by this fallback.
    static func fittingToolOutputs(_ messages: [[String: JSONValue]], maxBytes: Int) throws -> [[String: JSONValue]] {
        var fitted = messages
        var size = try encoded(fitted).count
        guard size > maxBytes else { return messages }
        let originals = Dictionary(uniqueKeysWithValues: messages.indices.compactMap { index -> (Int, String)? in
            guard messages[index]["role"] == .string("tool"),
                  case let .string(text) = messages[index]["content"] else { return nil }
            return (index, text)
        })
        let minimum = truncationMarker.utf8.count + 64
        while size > maxBytes {
            let candidates: [(Int, Int)] = originals.compactMap { index, _ in
                guard case let .string(text) = fitted[index]["content"], text.utf8.count > minimum else { return nil }
                return (index, text.utf8.count)
            }
            guard let (index, currentBytes) = candidates.max(by: { $0.1 < $1.1 }),
                  let original = originals[index] else { break }
            let reduction = max(size - maxBytes + 64, currentBytes / 8)
            let target = max(minimum, currentBytes - reduction)
            fitted[index]["content"] = .string(clippedToolOutput(original, maxBytes: target))
            let nextSize = try encoded(fitted).count
            guard nextSize < size else { break }
            size = nextSize
        }
        guard size <= maxBytes else { throw ContextSizeError.tooLarge }
        return fitted
    }

    private static func clippedToolOutput(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let available = max(0, maxBytes - truncationMarker.utf8.count)
        let headLimit = available * 3 / 4
        let tailLimit = available - headLimit
        var head = ""
        var tailScalars: [Unicode.Scalar] = []
        var headBytes = 0, tailBytes = 0
        for scalar in text.unicodeScalars {
            let count = scalar.utf8.count
            guard headBytes + count <= headLimit else { break }
            head.unicodeScalars.append(scalar)
            headBytes += count
        }
        for scalar in text.unicodeScalars.reversed() {
            let count = scalar.utf8.count
            guard tailBytes + count <= tailLimit else { break }
            tailScalars.append(scalar)
            tailBytes += count
        }
        return head + truncationMarker + String(String.UnicodeScalarView(tailScalars.reversed()))
    }

    /// Chunk on Unicode scalar boundaries so even very large tool output can be summarized incrementally.
    static func chunks(_ data: Data, maxBytes: Int) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        let limit = max(256, maxBytes)
        var output: [String] = []
        var current = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let count = scalar.utf8.count
            if bytes + count > limit && !current.isEmpty {
                output.append(current)
                current = ""
                bytes = 0
            }
            current.unicodeScalars.append(scalar)
            bytes += count
        }
        if !current.isEmpty { output.append(current) }
        return output
    }
}
