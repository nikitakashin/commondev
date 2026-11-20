import Foundation
import XCTest
import AgentCore
@testable import CommondevApp

@MainActor
final class CustomEndpointFlowTests: XCTestCase {
    func testPlanBlocksWritesAndRegularProjectModeCanApproveAnEdit() async throws {
        for planning in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("example.txt")
            try "old".write(to: file, atomically: true, encoding: .utf8)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CustomEndpointProtocol.self]
            let transport = URLSession(configuration: configuration)
            let storage = root.appendingPathComponent("storage")
            let app = AppModel(storageRoot: storage) {
                OpenAICompatibleClient(endpoint: $0, model: $1, apiKey: $2, session: transport)
            }
            app.newChat()
            app.setProjectFolder(root)
            app.useFreeModel = false
            app.endpoint = "https://example.test/v1/chat/completions"
            app.modelName = "local-test"
            app.setApprovalMode(planning ? .fullAccess : .projectEdits)
            app.setPlanMode(planning)
            app.addAttachments([file])
            app.draft = "Review example.txt"
            app.send()

            for _ in 0..<150 where app.isRunning && app.approval == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertNil(app.approval)
            XCTAssertFalse(app.isRunning)
            XCTAssertTrue(app.draftAttachments.isEmpty)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), planning ? "old" : "new")
            let reopened = AppModel(storageRoot: storage)
            XCTAssertEqual(reopened.approvalMode, .ask)
            XCTAssertEqual(reopened.isPlanning, planning)
            let saved = try XCTUnwrap(reopened.selectedSession)
            XCTAssertEqual(saved.messages.first?.attachments?.first?.content, "old")
            XCTAssertTrue(saved.conversation?.contains {
                guard case let .string(text) = $0["content"] else { return false }
                return text.contains("Attached files") && text.contains("example.txt") && text.contains("old")
            } == true)
        }
    }

    func testEffortStatusReportsSharedBudgetsInBothModes() async throws {
        for mode in [ChatWorkMode.high, .low, .ultracode] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CustomEndpointProtocol.self]
            let session = URLSession(configuration: configuration)
            let app = AppModel(storageRoot: root.appendingPathComponent("storage")) {
                OpenAICompatibleClient(endpoint: $0, model: $1, apiKey: $2, session: session)
            }
            let chat = ChatSession(name: "fixture", projectPath: root.path)
            app.sessions = [chat]
            app.selectSession(chat.id)
            app.useFreeModel = false
            app.endpoint = "https://example.test/v1/chat/completions"
            app.modelName = "local-test"
            XCTAssertEqual(app.selectedWorkMode, .high)
            app.setWorkMode(mode)
            app.draft = "Short task"
            app.send()
            let status = try XCTUnwrap(app.selectedSession?.messages.last(where: { $0.role == "system" })?.text)
            XCTAssertTrue(status.contains("Effort: \(mode.title)"))
            XCTAssertTrue(status.contains("запросов к модели: \(mode.effort.maxModelCalls)"))
            XCTAssertTrue(status.contains("действий инструментов: \(mode.effort.maxToolCalls)"))
            app.stop()
            for _ in 0..<150 {
                if !app.isRunning { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertFalse(app.isRunning)
        }
    }

    func testCustomEndpointApprovalAndRejectionSurviveRestart() async throws {
        for allowed in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("project")
            let storage = root.appendingPathComponent("storage")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let file = project.appendingPathComponent("example.txt")
            try "old".write(to: file, atomically: true, encoding: .utf8)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CustomEndpointProtocol.self]
            let session = URLSession(configuration: configuration)
            let app = AppModel(storageRoot: storage) {
                OpenAICompatibleClient(endpoint: $0, model: $1, apiKey: $2, session: session)
            }
            let chat = ChatSession(name: "fixture", projectPath: project.path)
            app.sessions = [chat]
            app.selectSession(chat.id)
            app.useFreeModel = false
            app.endpoint = "https://example.test/v1/chat/completions"
            app.modelName = "local-test"
            app.draft = "Change the fixture"
            app.send()

            for _ in 0..<150 {
                if app.approval != nil || !app.isRunning { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let approval = try XCTUnwrap(app.approval)
            XCTAssertTrue(approval.detail.contains("example.txt"))
            XCTAssertTrue(approval.detail.contains("-old"))
            XCTAssertTrue(approval.detail.contains("+new"))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
            app.resolveApproval(allowed)
            for _ in 0..<150 {
                if !app.isRunning { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertFalse(app.isRunning)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), allowed ? "new" : "old")
            XCTAssertTrue(app.selectedSession?.messages.contains(where: { $0.role == "assistant" && $0.text == "done" }) == true)
            let restored = AppModel(storageRoot: storage)
            let conversation = try XCTUnwrap(restored.selectedSession?.conversation)
            XCTAssertTrue(conversation.contains { $0["tool_call_id"] == .string("edit-1") })
            XCTAssertTrue(restored.selectedSession?.messages.contains(where: { $0.role == "assistant" && $0.text == "done" }) == true)
        }
    }
}

private final class CustomEndpointProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            data = body
        }
        let payload = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let messages = payload?["messages"] as? [[String: Any]] ?? []
        let hasResult = messages.contains { $0["role"] as? String == "tool" }
        let content = hasResult
            ? #"data: {"choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"#
            : #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"edit-1","type":"function","function":{"name":"replace_text","arguments":"{\"path\":\"example.txt\",\"old\":\"old\",\"new\":\"new\"}"}}]},"finish_reason":"tool_calls"}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((content + "\n\ndata: [DONE]\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
