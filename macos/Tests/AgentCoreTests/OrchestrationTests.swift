import Foundation
import XCTest
@testable import AgentCore

final class OrchestrationTests: XCTestCase {
    func testPlannerParsesFencedJSONAndBracesInStrings() {
        let plan = UltracodeRunner.planTasks(
            "Here is the plan:\n```json\n{\"tasks\":[\"Inspect {source}\",\"Review tests\"]}\n```",
            request: "check"
        )
        XCTAssertFalse(plan.usedFallback)
        XCTAssertEqual(plan.tasks, ["Inspect {source}", "Review tests"])
    }

    func testPlannerFallsBackWhenResponseHasNoValidTasks() {
        let plan = UltracodeRunner.planTasks("I cannot provide JSON {bad}", request: "inspect file")
        XCTAssertTrue(plan.usedFallback)
        XCTAssertEqual(plan.tasks.count, 1)
        XCTAssertTrue(plan.tasks[0].contains("inspect file"))
    }

    func testUltracodeReportsFallbackAndContinues() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let phases = PhaseRecorder()
        let result = try await UltracodeRunner.run(
            task: "invalid-plan", workspace: source, client: client(), maxModelCalls: 16,
            onEvent: { event in
                if case let .phase(phase) = event { await phases.append(phase) }
            }, approve: { _, _ in false }
        )
        let recorded = await phases.values
        XCTAssertTrue(recorded.contains { $0.contains("План не распознан") })
        XCTAssertEqual(result.research.count, 1)
        XCTAssertEqual(result.review, "done")
    }

    private func client() -> OpenAICompatibleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OrchestrationMock.self]
        return OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!, model: "test",
                                      session: URLSession(configuration: config))
    }

    func testChildEditsOnlyItsSnapshot() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let file = source.appendingPathComponent("file.txt")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let result = try await SubagentRunner.run(
            id: UUID(), task: "edit isolated file", workspace: source, client: client(),
            maxModelCalls: 2, onEvent: { _ in }, approve: { _, _ in true }
        )
        XCTAssertTrue(result.contains("done"))
        XCTAssertTrue(result.contains("--- a/file.txt"))
        XCTAssertTrue(result.contains("+++ b/file.txt"))
        XCTAssertTrue(result.contains("-old"))
        XCTAssertTrue(result.contains("+new"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
    }

    func testUltracodePlansResearchAndReview() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let result = try await UltracodeRunner.run(
            task: "investigate", workspace: source, client: client(), maxModelCalls: 25,
            onEvent: { _ in }, approve: { _, _ in false }
        )
        XCTAssertEqual(result.research.count, 2)
        XCTAssertEqual(result.answer, "done")
        XCTAssertEqual(result.review, "done")
    }

    func testUltracodePassesActiveInstructionsToMainAndChildren() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let result = try await UltracodeRunner.run(
            task: "profile-check", workspace: source, client: client(), maxModelCalls: 25,
            systemInstructions: "PROFILE-CHECK: apply active effort and Harness instructions",
            onEvent: { _ in }, approve: { _, _ in false }
        )
        XCTAssertEqual(result.research, ["profile applied", "profile applied"])
        XCTAssertEqual(result.answer, "profile applied")
        XCTAssertEqual(result.review, "profile applied")
    }

    func testUltracodeLowBudgetLeavesRoomForMainToolRoundTrip() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try "old".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let result = try await UltracodeRunner.run(
            task: "verify changed", workspace: source, client: client(), maxModelCalls: 16,
            onEvent: { _ in }, approve: { _, _ in true }
        )
        XCTAssertEqual(result.research.count, 1)
        XCTAssertEqual(result.answer, "done")
        XCTAssertEqual(result.review, "new")
    }

    func testUltracodeRejectsBudgetBelowMinimum() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        do {
            _ = try await UltracodeRunner.run(
                task: "inspect", workspace: source, client: client(), maxModelCalls: 8,
                onEvent: { _ in }, approve: { _, _ in false }
            )
            XCTFail("Expected a budget error.")
        } catch OrchestrationError.budget {
        }
    }

    func testModelCanDelegateThroughToolCall() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let agent = LiveAgent(workspace: source, client: client(), onEvent: { _ in }, approve: { _ in false },
                              delegate: { task in
            XCTAssertEqual(task, "research")
            return "report"
        })
        let answer = try await agent.run(task: "delegate")
        XCTAssertEqual(answer, "done")
    }

    func testStoppingDelegatedAgentDoesNotCancelParent() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let events = ToolResultRecorder()
        let agent = LiveAgent(workspace: source, client: client(), onEvent: { event in
            if case let .toolFinished(_, result) = event { await events.record(result) }
        }, approve: { _ in false }, delegate: { _ in throw CancellationError() })
        let answer = try await agent.run(task: "delegate")
        XCTAssertEqual(answer, "done")
        let results = await events.values
        XCTAssertTrue(results.contains { $0.contains("Субагент остановлен") })
    }

    func testStoppingParentStillCancelsDelegation() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let started = expectation(description: "child started")
        let agent = LiveAgent(workspace: source, client: client(), onEvent: { _ in }, approve: { _ in false },
                              delegate: { _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "unexpected"
        })
        let run = Task { try await agent.run(task: "delegate") }
        await fulfillment(of: [started], timeout: 5)
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("Cancelling the parent must cancel the run")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testReviewerSeesMainAgentsChanges() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try "old".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let result = try await UltracodeRunner.run(task: "verify changed", workspace: source, client: client(),
                                                  maxModelCalls: 16, onEvent: { _ in }, approve: { _, _ in true })
        XCTAssertEqual(result.review, "new")
    }

    func testReviewUsesRemainingCallsFromEarlierPhases() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try "content".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let result = try await UltracodeRunner.run(task: "long-review", workspace: source, client: client(),
                                                  maxModelCalls: 21, onEvent: { _ in }, approve: { _, _ in false })
        XCTAssertEqual(result.review, "finished after six reads")
    }

    func testSingleResearcherGetsSevenCallsWhenBudgetIsTwentyOne() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try "content".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let result = try await UltracodeRunner.run(task: "research-budget", workspace: source, client: client(),
                                                  maxModelCalls: 21, onEvent: { _ in }, approve: { _, _ in false })
        XCTAssertEqual(result.research, ["research completed after six reads"])
        XCTAssertEqual(result.review, "done")
    }

    func testSharedModelBudgetRejectsExtraRequest() async throws {
        let budget = ModelRequestBudget(maximum: 1)
        try await budget.consume()
        do {
            try await budget.consume()
            XCTFail("Expected shared budget exhaustion.")
        } catch {}
    }

    func testSharedToolBudgetIsIndependentOfModelBudget() async throws {
        let budget = ModelRequestBudget(maximum: 3, maxToolCalls: 1)
        try await budget.consumeTool()
        do {
            try await budget.consumeTool()
            XCTFail("Expected shared tool budget exhaustion.")
        } catch {}
        try await budget.consume()
    }
}

private final class OrchestrationMock: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
        }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let messages = object?["messages"] as? [[String: Any]] ?? []
        let system = messages.first?["content"] as? String ?? ""
        let user = messages.first(where: { $0["role"] as? String == "user" })?["content"] as? String ?? ""
        let hasResult = messages.contains { $0["role"] as? String == "tool" }
        var delta: [String: Any]
        var finish = "stop"
        if system.contains("Divide the coding request") {
            let response: String
            if user.contains("invalid-plan") {
                response = "I cannot produce a plan."
            } else if user.contains("research-budget") {
                response = "{\"tasks\":[\"research-budget-a\",\"research-budget-b\"]}"
            } else {
                response = "{\"tasks\":[\"research one\",\"research two\"]}"
            }
            delta = ["content": response]
        } else if system.contains("PROFILE-CHECK") {
            delta = ["content": "profile applied"]
        } else if user == "research-budget-a" {
            let count = messages.filter { $0["role"] as? String == "tool" }.count
            if count < 6 {
                delta = ["tool_calls": [["index": 0, "id": "research-read-\(count)", "type": "function",
                    "function": ["name": "read_file", "arguments": "{\"path\":\"file.txt\"}"]]]]
                finish = "tool_calls"
            } else {
                delta = ["content": "research completed after six reads"]
            }
        } else if user == "delegate" && !hasResult {
            delta = ["tool_calls": [["index": 0, "id": "delegate-1", "type": "function",
                "function": ["name": "delegate_task", "arguments": "{\"task\":\"research\"}"]]]]
            finish = "tool_calls"
        } else if (user == "edit isolated file" || user == "verify changed") && !hasResult {
            delta = ["tool_calls": [["index": 0, "id": "call-1", "type": "function",
                "function": ["name": "replace_text", "arguments": "{\"path\":\"file.txt\",\"old\":\"old\",\"new\":\"new\"}"]]]]
            finish = "tool_calls"
        } else if user.contains("Review the completed task") && user.contains("long-review") {
            let count = messages.filter { $0["role"] as? String == "tool" }.count
            if count < 6 {
                delta = ["tool_calls": [["index": 0, "id": "read-\(count)", "type": "function",
                    "function": ["name": "read_file", "arguments": "{\"path\":\"file.txt\"}"]]]]
                finish = "tool_calls"
            } else {
                delta = ["content": "finished after six reads"]
            }
        } else if user.contains("Review the completed task") && user.contains("verify changed") {
            if !hasResult {
                delta = ["tool_calls": [["index": 0, "id": "read-1", "type": "function",
                    "function": ["name": "read_file", "arguments": "{\"path\":\"file.txt\"}"]]]]
                finish = "tool_calls"
            } else {
                delta = ["content": messages.last?["content"] as? String ?? ""]
            }
        } else {
            delta = ["content": "done"]
        }
        let chunk: [String: Any] = ["choices": [["index": 0, "delta": delta, "finish_reason": finish]]]
        let json = try! JSONSerialization.data(withJSONObject: chunk)
        let data = Data("data: ".utf8) + json + Data("\n\ndata: [DONE]\n\n".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor PhaseRecorder {
    private(set) var values: [String] = []
    func append(_ phase: String) { values.append(phase) }
}

private actor ToolResultRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
