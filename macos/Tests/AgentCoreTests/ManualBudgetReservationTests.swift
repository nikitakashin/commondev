import Foundation
import XCTest
@testable import AgentCore

final class ManualBudgetReservationTests: XCTestCase {
    func testParallelChildrenCannotConsumeParentsLastRequest() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "fixture".write(to: workspace.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReservedBudgetProtocol.self]
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://example.test")!, model: "test",
                                            session: URLSession(configuration: config))
        let budget = ModelRequestBudget(maximum: 4, maxToolCalls: 20)
        let state = ReservedBudgetState()
        let agent = LiveAgent(workspace: workspace, client: client,
                              onEvent: { event in
                                  if case let .conversation(messages) = event { await state.setHistory(messages) }
                              }, approve: { _ in false }, maxModelCalls: 4,
                              requestBudget: budget, delegate: { child in
            try await SubagentRunner.run(id: UUID(), task: child, workspace: workspace, client: client,
                                        maxModelCalls: 4, requestBudget: budget, reservedModelCalls: 1,
                                        onEvent: { _ in }, approve: { _, _ in false })
        })
        let answer = try await agent.run(task: "parent")
        XCTAssertEqual(answer, "parent completed")
        let remaining = await budget.remainingModelCalls()
        XCTAssertEqual(remaining, 0)
        let messages = await state.history
        let results = messages.filter { $0["role"] == .string("tool") }
        XCTAssertEqual(results.count, 2)
        for result in results {
            guard case let .string(text) = result["content"] else { return XCTFail("Missing child result") }
            XCTAssertTrue(text.contains("лимит обращений"))
        }
    }

    func testReservationIsAtomicAcrossConcurrentChildren() async throws {
        let budget = ModelRequestBudget(maximum: 3)
        let consumed = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do { try await budget.consume(reserving: 1); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        XCTAssertEqual(consumed, 2)
        try await budget.consume()
        let remaining = await budget.remainingModelCalls()
        XCTAssertEqual(remaining, 0)
    }
}

private actor ReservedBudgetState {
    private(set) var history: [[String: JSONValue]] = []
    func setHistory(_ value: [[String: JSONValue]]) { history = value }
}

private final class ReservedBudgetProtocol: URLProtocol {
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
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let messages = payload?["messages"] as? [[String: Any]] ?? []
        let user = messages.first { $0["role"] as? String == "user" }?["content"] as? String ?? ""
        let hasResult = messages.contains { $0["role"] as? String == "tool" }
        func call(_ index: Int, _ id: String, _ name: String, _ arguments: String) -> [String: Any] {
            ["index": index, "id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
        }
        let delta: [String: Any]
        let finish: String
        if user == "parent" && !hasResult {
            delta = ["tool_calls": [call(0, "a", "delegate_task", "{\"task\":\"child-a\"}"),
                                    call(1, "b", "delegate_task", "{\"task\":\"child-b\"}")]]
            finish = "tool_calls"
        } else if user != "parent" {
            delta = ["tool_calls": [call(0, "read", "read_file", "{\"path\":\"file.txt\"}")]]
            finish = "tool_calls"
        } else {
            delta = ["content": "parent completed"]
            finish = "stop"
        }
        let json = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": delta, "finish_reason": finish]]])
        let output = Data("data: ".utf8) + json + Data("\n\ndata: [DONE]\n\n".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: output)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
