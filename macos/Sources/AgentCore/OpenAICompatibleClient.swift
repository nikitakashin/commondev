import Foundation
import CryptoKit

/// JSON values used by OpenAI-compatible messages and tool definitions.
public enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let value = try? value.decode(Bool.self) { self = .bool(value) }
        else if let value = try? value.decode(Double.self) { self = .number(value) }
        else if let value = try? value.decode(String.self) { self = .string(value) }
        else if let value = try? value.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct OpenAIToolCall {
    public let id: String
    public let name: String
    public let argumentsJSON: String
}

public struct OpenAIResponse {
    public let text: String
    public let toolCalls: [OpenAIToolCall]
    public let routedVia: String?
    public let actualModel: String?
}

/// Only opt in when the selected model and endpoint explicitly support this field.
public enum ReasoningEffort: String, Sendable {
    case low, medium, high
}

public enum OpenAIClientError: LocalizedError {
    case http(Int, String)
    case invalidResponse(String)
    case incompleteStream
    case provider(String)
    /// The transport timed out before any response delta arrived.
    case retryableTimeout

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message): return "HTTP \(status): \(message)"
        case .invalidResponse(let message): return "Invalid model response: \(message)"
        case .incompleteStream: return "The model response ended before completion."
        case .provider(let message): return "Model request failed: \(message)"
        case .retryableTimeout: return "Время ожидания модели истекло до начала ответа."
        }
    }
}

/// Executes one streaming chat completion. The caller owns message history and tool execution.
public struct OpenAICompatibleClient: Sendable {
    private let endpoint: URL
    private let model: String
    private let apiKey: String?
    private let session: URLSession
    private let supportsReasoningEffort: Bool
    private let defaultReasoningEffort: ReasoningEffort?
    private let identifyDirectEndpoint: Bool

    public init(endpoint: URL, model: String, apiKey: String? = nil, session: URLSession = .shared,
                supportsReasoningEffort: Bool = false, defaultReasoningEffort: ReasoningEffort? = nil,
                identifyDirectEndpoint: Bool = false) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.session = session
        self.supportsReasoningEffort = supportsReasoningEffort
        self.defaultReasoningEffort = defaultReasoningEffort
        self.identifyDirectEndpoint = identifyDirectEndpoint
    }

    public func selectingModel(_ model: String) -> OpenAICompatibleClient {
        OpenAICompatibleClient(endpoint: endpoint, model: model, apiKey: apiKey, session: session,
                               supportsReasoningEffort: supportsReasoningEffort, defaultReasoningEffort: defaultReasoningEffort,
                               identifyDirectEndpoint: identifyDirectEndpoint)
    }

    /// Call only after the user confirms that their endpoint and model support this field.
    public func enablingReasoningEffort(_ effort: ReasoningEffort) -> OpenAICompatibleClient {
        OpenAICompatibleClient(endpoint: endpoint, model: model, apiKey: apiKey, session: session,
                               supportsReasoningEffort: true, defaultReasoningEffort: effort,
                               identifyDirectEndpoint: identifyDirectEndpoint)
    }

    /// Used only for an explicitly configured endpoint, never an automatic
    /// provider router. The URL fingerprint identifies the responding endpoint,
    /// not an inferred underlying provider, and does not expose URL credentials.
    public func identifyingDirectEndpoint() -> OpenAICompatibleClient {
        OpenAICompatibleClient(endpoint: endpoint, model: model, apiKey: apiKey, session: session,
                               supportsReasoningEffort: supportsReasoningEffort, defaultReasoningEffort: defaultReasoningEffort,
                               identifyDirectEndpoint: true)
    }

    public func complete(
        messages: [[String: JSONValue]],
        tools: [[String: JSONValue]],
        reasoningEffort: ReasoningEffort? = nil,
        onText: @escaping (String) async -> Void = { _ in }
    ) async throws -> OpenAIResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var payload: [String: JSONValue] = [
            "model": .string(model), "stream": .bool(true),
            "messages": .array(messages.map(JSONValue.object))
        ]
        if !tools.isEmpty { payload["tools"] = .array(tools.map(JSONValue.object)) }
        if supportsReasoningEffort, let reasoningEffort = reasoningEffort ?? defaultReasoningEffort {
            payload["reasoning_effort"] = .string(reasoningEffort.rawValue)
        }
        request.httpBody = try JSONEncoder().encode(payload)
        let bytes: URLSession.AsyncBytes
        let rawResponse: URLResponse
        do {
            (bytes, rawResponse) = try await session.bytes(for: request)
        } catch {
            if Self.isTimeout(error) { throw OpenAIClientError.retryableTimeout }
            throw error
        }
        guard let response = rawResponse as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse("Response was not HTTP")
        }
        guard (200..<300).contains(response.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 4096 { break }
            }
            throw OpenAIClientError.http(response.statusCode, String(decoding: body, as: UTF8.self))
        }
        var parser = SSECompletionParser()
        var lineData = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                if byte == 10 {
                    if lineData.last == 13 { lineData.removeLast() }
                    guard let line = String(data: lineData, encoding: .utf8) else {
                        throw OpenAIClientError.invalidResponse("Invalid UTF-8 in SSE stream")
                    }
                    lineData.removeAll(keepingCapacity: true)
                    try parser.consume(line)
                    for chunk in parser.takeText() { await onText(chunk) }
                    if parser.done { break }
                } else {
                    lineData.append(byte)
                    guard lineData.count <= 8_388_608 else {
                        throw OpenAIClientError.invalidResponse("SSE event line exceeds limit")
                    }
                }
            }
        } catch {
            // A partial SSE frame may contain a tool call. Never retry until it
            // has been fully parsed, even if no text has been displayed.
            if Self.isTimeout(error), lineData.isEmpty, parser.canRetry {
                throw OpenAIClientError.retryableTimeout
            }
            throw error
        }
        try Task.checkCancellation()
        let route = response.value(forHTTPHeaderField: "X-Routed-Via") ??
            (identifyDirectEndpoint ? response.url.map(Self.endpointIdentity) : nil)
        return try parser.finish(routedVia: route)
    }

    private static func endpointIdentity(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return "endpoint-sha256:" + digest
    }

    private static func isTimeout(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut
    }
}

private struct Fragment: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct Tool: Decodable {
                struct Function: Decodable { let name: String?; let arguments: String? }
                let index: Int
                let id: String?
                let type: String?
                let function: Function?
            }
            let content: String?
            let tool_calls: [Tool]?
        }
        let index: Int?
        let delta: Delta?
        let finish_reason: String?
    }
    struct ErrorBody: Decodable { let message: String? }
    let choices: [Choice]?
    let error: ErrorBody?
    let model: String?
}

private struct SSECompletionParser {
    private struct ToolParts { var id = ""; var name = ""; var arguments = "" }
    private var toolParts: [Int: ToolParts] = [:]
    private var dataLines: [String] = []
    private var text = ""
    private var reason: String?
    private var pendingText: [String] = []
    private var actualModel: String?
    private var receivedDelta = false
    private(set) var done = false
    var canRetry: Bool { !receivedDelta && dataLines.isEmpty && !done }

    mutating func takeText() -> [String] {
        defer { pendingText.removeAll() }
        return pendingText
    }

    mutating func consume(_ line: String) throws {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return }
            let data = dataLines.joined(separator: "\n")
            dataLines.removeAll()
            if data == "[DONE]" { done = true; return }
            let fragment: Fragment
            do { fragment = try JSONDecoder().decode(Fragment.self, from: Data(data.utf8)) }
            catch { throw OpenAIClientError.invalidResponse("Malformed SSE JSON") }
            if let error = fragment.error { throw OpenAIClientError.provider(error.message ?? "Unknown provider error") }
            if let model = fragment.model, !model.isEmpty {
                if let actualModel, actualModel != model {
                    throw OpenAIClientError.invalidResponse("Model changed during the response")
                }
                actualModel = model
            }
            for choice in fragment.choices ?? [] where (choice.index ?? 0) == 0 {
                if choice.delta != nil { receivedDelta = true }
                if let content = choice.delta?.content { text += content; pendingText.append(content) }
                for part in choice.delta?.tool_calls ?? [] {
                    guard part.index >= 0 else { throw OpenAIClientError.invalidResponse("Invalid tool index") }
                    guard part.type == nil || part.type == "function" else {
                        throw OpenAIClientError.invalidResponse("Unsupported tool type")
                    }
                    var tool = toolParts[part.index] ?? ToolParts()
                    if let id = part.id { tool.id += id }
                    if let name = part.function?.name { tool.name += name }
                    if let args = part.function?.arguments { tool.arguments += args }
                    toolParts[part.index] = tool
                }
                if let finish = choice.finish_reason { reason = finish }
            }
        } else if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
    }

    mutating func finish(routedVia: String?) throws -> OpenAIResponse {
        guard done, let reason else { throw OpenAIClientError.incompleteStream }
        guard reason == "stop" || reason == "tool_calls" else {
            throw OpenAIClientError.provider("Completion stopped: \(reason)")
        }
        if reason == "stop" && !toolParts.isEmpty || reason == "tool_calls" && toolParts.isEmpty {
            throw OpenAIClientError.invalidResponse("Finish reason does not match tool calls")
        }
        var ids = Set<String>()
        let calls = try toolParts.keys.sorted().map { index -> OpenAIToolCall in
            let parts = toolParts[index]!
            guard !parts.id.isEmpty, !parts.name.isEmpty, ids.insert(parts.id).inserted,
                  let data = parts.arguments.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
                throw OpenAIClientError.invalidResponse("Incomplete or invalid tool call")
            }
            return OpenAIToolCall(id: parts.id, name: parts.name, argumentsJSON: parts.arguments)
        }
        return OpenAIResponse(text: text, toolCalls: calls, routedVia: routedVia, actualModel: actualModel)
    }
}
