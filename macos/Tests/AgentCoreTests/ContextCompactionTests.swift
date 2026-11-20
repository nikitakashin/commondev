import Foundation
import XCTest
@testable import AgentCore

final class ContextCompactionTests: XCTestCase {
    private func client() -> OpenAICompatibleClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompactionMock.self]
        return OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!,
                                     model: "test", session: URLSession(configuration: configuration))
    }

    func testCompactionPreservesFullHistoryAndCanResume() async throws {
        CompactionMock.requests = []
        CompactionMock.failSummary = false
        let first: [[String: JSONValue]] = [
            ["role": .string("user"), "content": .string(String(repeating: "старые данные ", count: 200))],
            ["role": .string("assistant"), "content": .null,
             "tool_calls": .array([.object(["id": .string("old-call"), "type": .string("function"),
                 "function": .object(["name": .string("read_file"), "arguments": .string("{}")])])])],
            ["role": .string("tool"), "tool_call_id": .string("old-call"), "content": .string("old result")],
            ["role": .string("user"), "content": .string("recent question")],
            ["role": .string("assistant"), "content": .string("recent answer")]
        ]
        let capture = CompactionCapture()
        let agent = LiveAgent(workspace: FileManager.default.temporaryDirectory, client: client(),
                              onEvent: { event in
            if case let .conversation(messages) = event { await capture.setHistory(messages) }
        }, approve: { _ in false }, contextByteLimit: 2_048,
                              onCompaction: { await capture.setCompaction($0) })
        _ = try await agent.run(task: "current task", history: first)
        let captured = await capture.compaction()
        let saved = try XCTUnwrap(captured)
        XCTAssertEqual(saved.coveredCount, 3)
        let full = await capture.history()
        XCTAssertEqual(full.prefix(first.count).map { $0 }, first)
        let normal = try XCTUnwrap(CompactionMock.requests.last)
        let messages = try Self.messages(in: normal)
        XCTAssertEqual(messages[1]["role"] as? String, "system")
        XCTAssertTrue((messages[1]["content"] as? String ?? "").contains("Compact summary"))
        XCTAssertFalse(messages.contains { ($0["tool_call_id"] as? String) == "old-call" })
        XCTAssertTrue(messages.contains { ($0["content"] as? String) == "recent question" })
        let count = CompactionMock.requests.count
        _ = try await agent.run(task: "another task", history: full, resumeCompaction: saved)
        XCTAssertEqual(CompactionMock.requests.count, count + 1, "A valid saved summary should be reused")
        let replay = try Self.messages(in: XCTUnwrap(CompactionMock.requests.last))
        XCTAssertTrue(replay.contains { ($0["content"] as? String ?? "").contains("Compact summary") })
    }

    func testChangedPrefixInvalidatesSavedSummary() throws {
        let history: [[String: JSONValue]] = [
            ["role": .string("user"), "content": .string("original")],
            ["role": .string("assistant"), "content": .string("answer")],
            ["role": .string("user"), "content": .string("recent")]
        ]
        let state = ContextCompaction(coveredCount: 2,
                                      coveredDigest: try ContextCompaction.digest(Array(history.prefix(2))),
                                      summary: "summary")
        var changed = history
        changed[0]["content"] = .string("modified")
        let system: [String: JSONValue] = ["role": .string("system"), "content": .string("system")]
        XCTAssertEqual(ContextCompactor.activeMessages(system: system, history: changed, state: state), [system] + changed)
    }

    func testFailedSummaryDoesNotPublishCompaction() async throws {
        CompactionMock.requests = []
        CompactionMock.failSummary = true
        defer { CompactionMock.failSummary = false }
        let capture = CompactionCapture()
        let agent = LiveAgent(workspace: FileManager.default.temporaryDirectory, client: client(),
                              onEvent: { _ in }, approve: { _ in false }, contextByteLimit: 1_024,
                              onCompaction: { await capture.setCompaction($0) })
        let history: [[String: JSONValue]] = [
            ["role": .string("user"), "content": .string(String(repeating: "old", count: 1_000))],
            ["role": .string("assistant"), "content": .string("answer")],
            ["role": .string("user"), "content": .string("recent")]
        ]
        do {
            _ = try await agent.run(task: "current", history: history)
            XCTFail("Expected failure")
        } catch OpenAIClientError.http(let status, _) { XCTAssertEqual(status, 500) }
        let state = await capture.compaction()
        XCTAssertNil(state)
    }

    func testBudgetExhaustionRetainsCompletedTurnCheckpoint() async throws {
        CompactionMock.requests = []
        CompactionMock.failSummary = false
        let capture = CompactionCapture()
        let agent = LiveAgent(workspace: FileManager.default.temporaryDirectory, client: client(),
                              onEvent: { _ in }, approve: { _ in false }, maxModelCalls: 2,
                              contextByteLimit: 1_024, onCompaction: { await capture.setCompaction($0) })
        let history: [[String: JSONValue]] = [
            ["role": .string("user"), "content": .string(String(repeating: "a", count: 250))],
            ["role": .string("assistant"), "content": .string("first")],
            ["role": .string("user"), "content": .string(String(repeating: "b", count: 250))],
            ["role": .string("assistant"), "content": .string("second")],
            ["role": .string("user"), "content": .string("recent")]
        ]
        do {
            _ = try await agent.run(task: String(repeating: "c", count: 400), history: history)
            XCTFail("Expected budget exhaustion")
        } catch {
            let saved = await capture.compaction()
            XCTAssertEqual(saved?.coveredCount, 2)
        }
    }

    func testLargeToolResultsAreShortenedTogetherWithoutChangingHistoryOrOrdering() throws {
        let first = String(repeating: "тест\n\"🙂", count: 1_000)
        let second = String(repeating: "data\\\n", count: 1_000)
        let original: [[String: JSONValue]] = [
            ["role": .string("system"), "content": .string("system")],
            ["role": .string("user"), "content": .string("Не изменяй инструкции")],
            ["role": .string("assistant"), "tool_calls": .array([
                .object(["id": .string("one")]), .object(["id": .string("two")])
            ])],
            ["role": .string("tool"), "tool_call_id": .string("one"), "content": .string(first)],
            ["role": .string("tool"), "tool_call_id": .string("two"), "content": .string(second)]
        ]
        let fitted = try ContextCompactor.fittingToolOutputs(original, maxBytes: 2_000)
        XCTAssertLessThanOrEqual(try ContextCompactor.encoded(fitted).count, 2_000)
        XCTAssertEqual(fitted.map { $0["role"] }, original.map { $0["role"] })
        XCTAssertEqual(fitted[2], original[2])
        XCTAssertEqual(fitted[1], original[1])
        XCTAssertEqual(fitted[3]["tool_call_id"], .string("one"))
        XCTAssertEqual(fitted[4]["tool_call_id"], .string("two"))
        for message in fitted.suffix(2) {
            guard case let .string(text) = message["content"] else { return XCTFail("Missing tool output") }
            XCTAssertTrue(text.contains("полный вывод сохранён в истории"))
        }
        XCTAssertEqual(original[3]["content"], .string(first))
        XCTAssertEqual(original[4]["content"], .string(second))
    }

    func testOversizedUserMessageFailsBeforeSendingRequest() async throws {
        CompactionMock.requests = []
        let agent = LiveAgent(workspace: FileManager.default.temporaryDirectory, client: client(),
                              onEvent: { _ in }, approve: { _ in false }, contextByteLimit: 1_024)
        let history: [[String: JSONValue]] = [
            ["role": .string("user"), "content": .string("first")],
            ["role": .string("assistant"), "content": .string("answer")],
            ["role": .string("user"), "content": .string("second")],
            ["role": .string("assistant"), "content": .string("answer")]
        ]
        do {
            _ = try await agent.run(task: String(repeating: "не сокращать", count: 1_000), history: history)
            XCTFail("Expected an explicit context size error")
        } catch ContextSizeError.tooLarge {}
        XCTAssertTrue(CompactionMock.requests.isEmpty)
    }

    func testShortRequestCanFollowOversizedUserTurnFromOlderVersion() async throws {
        CompactionMock.requests = []
        CompactionMock.failSummary = false
        let history: [[String: JSONValue]] = [
            ["role": .string("user"), "content": .string(String(repeating: "x", count: 2_100))]
        ]
        let agent = LiveAgent(workspace: FileManager.default.temporaryDirectory, client: client(),
                              onEvent: { _ in }, approve: { _ in false }, contextByteLimit: 2_048)
        let result = try await agent.run(task: "shorter", history: history)
        XCTAssertEqual(result, "Done")
        let messages = try Self.messages(in: XCTUnwrap(CompactionMock.requests.last))
        XCTAssertEqual(messages.last?["content"] as? String, "shorter")
    }

    func testSummaryRequestsStayWithinContextLimitWithEscapedContent() async throws {
        CompactionMock.requests = []
        CompactionMock.failSummary = false
        let history: [[String: JSONValue]] = [
            ["role": .string("user"), "content": .string(String(repeating: "\\\"", count: 400))],
            ["role": .string("assistant"), "content": .string("answer")],
            ["role": .string("user"), "content": .string("recent")],
            ["role": .string("assistant"), "content": .string("recent answer")]
        ]
        let agent = LiveAgent(workspace: FileManager.default.temporaryDirectory, client: client(),
                              onEvent: { _ in }, approve: { _ in false }, maxModelCalls: 30,
                              contextByteLimit: 1_024)
        _ = try await agent.run(task: "current", history: history)
        for request in CompactionMock.requests {
            let messages = try Self.messages(in: request)
            let encoded = try JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys])
            XCTAssertLessThanOrEqual(encoded.count, 1_024)
        }
    }

    private static func messages(in request: Data) throws -> [[String: Any]] {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        return try XCTUnwrap(body["messages"] as? [[String: Any]])
    }
}

private actor CompactionCapture {
    private var saved: ContextCompaction?
    private var full: [[String: JSONValue]] = []
    func setCompaction(_ value: ContextCompaction) { saved = value }
    func setHistory(_ value: [[String: JSONValue]]) { full = value }
    func compaction() -> ContextCompaction? { saved }
    func history() -> [[String: JSONValue]] { full }
}

private final class CompactionMock: URLProtocol {
    static var requests: [Data] = []
    static var failSummary = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
            stream.close()
        }
        Self.requests.append(body)
        let summary = String(decoding: body, as: UTF8.self).contains("Summarize earlier coding-agent history")
        let status = summary && Self.failSummary ? 500 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let text = summary ? "Compact summary" : "Done"
        let payload = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(text)\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
