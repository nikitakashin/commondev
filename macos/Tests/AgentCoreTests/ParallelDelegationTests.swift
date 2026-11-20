import Foundation
import XCTest
@testable import AgentCore

final class ParallelDelegationTests: XCTestCase {
    private func client() -> OpenAICompatibleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ParallelDelegationProtocol.self]
        return OpenAICompatibleClient(endpoint: URL(string: "https://example.test")!, model: "test",
                                      session: URLSession(configuration: config))
    }

    func testChildrenRunTogetherAndCancelledChildDoesNotStopOther() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let state = ParallelState()
        let agent = LiveAgent(workspace: workspace, client: client(), onEvent: { event in
            if case let .conversation(messages) = event { await state.setHistory(messages) }
        }, approve: { _ in false }, delegate: { name in
            await state.started(name)
            for _ in 0..<150 {
                if await state.startCount == 2 { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard await state.startCount == 2 else { throw ParallelTestError.notConcurrent }
            if name == "alpha" { throw CancellationError() }
            return "beta report"
        })
        let answer = try await agent.run(task: "delegate-batch")
        XCTAssertEqual(answer, "done")
        let results = await state.history.filter { $0["role"] == .string("tool") }
        XCTAssertEqual(results.map { $0["tool_call_id"] }, [.string("delegate-1"), .string("delegate-2")])
        guard case let .string(first) = results.first?["content"] else { return XCTFail("Missing first result") }
        XCTAssertTrue(first.contains("Субагент остановлен"))
        XCTAssertEqual(results.last?["content"], .string("beta report"))
    }

    func testStoppingParentPreservesAlreadyCompletedOutOfOrderResult() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let state = ParallelState()
        let betaDone = expectation(description: "second child finished")
        let agent = LiveAgent(workspace: workspace, client: client(), onEvent: { event in
            if case let .conversation(messages) = event { await state.setHistory(messages) }
            if case let .toolFinished(id, _) = event, id == "delegate-2" { betaDone.fulfill() }
        }, approve: { _ in false }, delegate: { name in
            if name == "alpha" { try await Task.sleep(nanoseconds: 30_000_000_000) }
            return "beta report"
        })
        let run = Task { try await agent.run(task: "delegate-batch") }
        await fulfillment(of: [betaDone], timeout: 5)
        run.cancel()
        do { _ = try await run.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let results = await state.history.filter { $0["role"] == .string("tool") }
        XCTAssertEqual(results.map { $0["tool_call_id"] }, [.string("delegate-1"), .string("delegate-2")])
        XCTAssertEqual(results.last?["content"], .string("beta report"))
        guard case let .string(first) = results.first?["content"] else { return XCTFail("Missing interrupted result") }
        XCTAssertTrue(first.contains("прервано"))
    }

    func testMixedBatchRunsEditsAfterBothDelegations() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("file.txt")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let state = ParallelState()
        let agent = LiveAgent(workspace: workspace, client: client(), onEvent: { event in
            if case let .toolStarted(_, description) = event { await state.toolStarted(description) }
        }, approve: { _ in true }, delegate: { name in
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
            await state.started(name)
            for _ in 0..<150 {
                if await state.startCount == 2 { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard await state.startCount == 2 else { throw ParallelTestError.notConcurrent }
            return name
        })
        let answer = try await agent.run(task: "delegate-mixed")
        XCTAssertEqual(answer, "done")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        let tools = await state.tools
        XCTAssertEqual(tools, ["read_file", "delegate_task", "delegate_task", "replace_text"])
    }

    func testBudgetExhaustionKeepsAllToolResultsInCheckpoint() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let state = ParallelState()
        let agent = LiveAgent(workspace: workspace, client: client(), onEvent: { event in
            if case let .conversation(messages) = event { await state.setHistory(messages) }
        }, approve: { _ in false }, maxToolCalls: 1, delegate: { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "unexpected"
        })
        do { _ = try await agent.run(task: "delegate-batch"); XCTFail("Expected exhausted budget") } catch {}
        let results = await state.history.filter { $0["role"] == .string("tool") }
        XCTAssertEqual(results.map { $0["tool_call_id"] }, [.string("delegate-1"), .string("delegate-2")])
        XCTAssertTrue(results.allSatisfy { result in
            guard case let .string(text) = result["content"] else { return false }
            return text.contains("прервано")
        })
    }
}

private enum ParallelTestError: Error { case notConcurrent }
private actor ParallelState {
    private(set) var startCount = 0
    private(set) var history: [[String: JSONValue]] = []
    private(set) var tools: [String] = []
    func started(_ name: String) { startCount += 1 }
    func setHistory(_ messages: [[String: JSONValue]]) { history = messages }
    func toolStarted(_ name: String) { tools.append(name) }
}

private final class ParallelDelegationProtocol: URLProtocol {
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
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let messages = object?["messages"] as? [[String: Any]] ?? []
        let user = messages.first { $0["role"] as? String == "user" }?["content"] as? String ?? ""
        let hasResult = messages.contains { $0["role"] as? String == "tool" }
        let delta: [String: Any]
        let finish: String
        if !hasResult {
            func call(_ index: Int, _ id: String, _ name: String, _ arguments: String) -> [String: Any] {
                ["index": index, "id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
            }
            var calls: [[String: Any]] = []
            if user == "delegate-mixed" { calls.append(call(calls.count, "read-1", "read_file", "{\"path\":\"file.txt\"}")) }
            calls.append(call(calls.count, "delegate-1", "delegate_task", "{\"task\":\"alpha\"}"))
            calls.append(call(calls.count, "delegate-2", "delegate_task", "{\"task\":\"beta\"}"))
            if user == "delegate-mixed" { calls.append(call(calls.count, "edit-1", "replace_text", "{\"path\":\"file.txt\",\"old\":\"old\",\"new\":\"new\"}")) }
            delta = ["tool_calls": calls]
            finish = "tool_calls"
        } else { delta = ["content": "done"]; finish = "stop" }
        let chunk: [String: Any] = ["choices": [["index": 0, "delta": delta, "finish_reason": finish]]]
        let json = try! JSONSerialization.data(withJSONObject: chunk)
        let output = Data("data: ".utf8) + json + Data("\n\ndata: [DONE]\n\n".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: output)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
