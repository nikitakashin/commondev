import Foundation
import XCTest
@testable import AgentCore

final class OversizedToolOutputTests: XCTestCase {
    func testLargeCurrentToolResultIsBoundedForModelButSavedInFull() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = "START " + String(repeating: "пример🙂", count: 8_000) + " END"
        try content.write(to: root.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedOutputProtocol.self]
        OversizedOutputProtocol.reset()
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!,
            model: "test", session: URLSession(configuration: configuration))
        let capture = OversizedHistoryCapture()
        let agent = LiveAgent(workspace: root, client: client, onEvent: { event in
            if case let .conversation(history) = event { await capture.set(history) }
        }, approve: { _ in false }, contextByteLimit: 2_048)
        let answer = try await agent.run(task: "Read the file")
        XCTAssertEqual(answer, "done")

        let requests = OversizedOutputProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1]) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let outgoing = try XCTUnwrap(messages.first { $0["role"] as? String == "tool" })
        let shortened = try XCTUnwrap(outgoing["content"] as? String)
        XCTAssertEqual(outgoing["tool_call_id"] as? String, "large-call")
        XCTAssertTrue(shortened.contains("сокращён для контекста"))
        XCTAssertTrue(shortened.hasPrefix("START "))
        XCTAssertTrue(shortened.hasSuffix(" END"))
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: messages).count, 2_048)
        let saved = await capture.get()
        XCTAssertEqual(saved.first { $0["role"] == .string("tool") }?["content"], .string(content))
    }

    func testOversizedUserInstructionsAreNeverTruncated() throws {
        let original: [[String: JSONValue]] = [
            ["role": .string("system"), "content": .string("system")],
            ["role": .string("user"), "content": .string(String(repeating: "важно ", count: 30))],
            ["role": .string("tool"), "tool_call_id": .string("id"), "content": .string(String(repeating: "x", count: 5_000))]
        ]
        let fitted = try ContextCompactor.fittingToolOutputs(original, maxBytes: 1_024)
        XCTAssertLessThanOrEqual(try ContextCompactor.encoded(fitted).count, 1_024)
        XCTAssertEqual(fitted[1], original[1])
        XCTAssertEqual(fitted[2]["tool_call_id"], .string("id"))
        XCTAssertEqual(original[2]["content"], .string(String(repeating: "x", count: 5_000)))
        guard case let .string(toolResult) = fitted[2]["content"] else { return XCTFail("Missing tool result") }
        XCTAssertTrue(toolResult.contains("сокращён для контекста"))
    }
}

private actor OversizedHistoryCapture {
    private var history: [[String: JSONValue]] = []
    func set(_ value: [[String: JSONValue]]) { history = value }
    func get() -> [[String: JSONValue]] { history }
}

private final class OversizedOutputProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [Data] = []
    static func reset() { lock.lock(); defer { lock.unlock() }; recorded = [] }
    static func requests() -> [Data] { lock.lock(); defer { lock.unlock() }; return recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
        }
        Self.lock.lock()
        Self.recorded.append(data)
        let first = Self.recorded.count == 1
        Self.lock.unlock()
        let payload = first
            ? #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"large-call","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"large.txt\",\"max_bytes\":1000000}"}}]},"finish_reason":"tool_calls"}]}"#
            : #"data: {"choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((payload + "\n\ndata: [DONE]\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
