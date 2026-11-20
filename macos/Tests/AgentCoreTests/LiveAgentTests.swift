import Foundation
import XCTest
@testable import AgentCore

final class LiveAgentTests: XCTestCase {
    func testGlobalChatCanChangeAnAbsolutePathWithApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentMockProtocol.self]
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!,
            model: "test", session: URLSession(configuration: configuration))
        AgentMockProtocol.editPath = file.path
        defer { AgentMockProtocol.editPath = "file.txt" }
        for (global, readOnly, approved) in [(false, false, false), (true, true, false), (true, false, true)] {
            AgentMockProtocol.requests = []
            AgentMockProtocol.bodies = []
            let agent = LiveAgent(workspace: workspace, client: client, global: global, readOnly: readOnly,
                                  onEvent: { _ in }, approve: { request in
                XCTAssertTrue(approved)
                guard case let .edit(path, _) = request else { return false }
                XCTAssertEqual(path, file.path)
                XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), "old")
                return true
            })
            _ = try await agent.run(task: "Change the fixture")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), approved ? "new" : "old")
        }
    }

    func testReplaceRejectsSymlinkRetargetedDuringApprovalEvenWhenContentsMatch() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let original = workspace.appendingPathComponent("original.txt")
        let other = workspace.appendingPathComponent("other.txt")
        let link = workspace.appendingPathComponent("file.txt")
        try "old".write(to: original, atomically: true, encoding: .utf8)
        try "old".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentMockProtocol.self]
        AgentMockProtocol.requests = []
        AgentMockProtocol.bodies = []
        AgentMockProtocol.action = "replace"
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!,
            model: "test", session: URLSession(configuration: configuration))
        let agent = LiveAgent(workspace: workspace, client: client, onEvent: { _ in }, approve: { _ in
            do {
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
                return true
            } catch {
                XCTFail("Could not retarget test link: \(error)")
                return false
            }
        })
        _ = try await agent.run(task: "Change the file")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "old")
        let data = try XCTUnwrap(AgentMockProtocol.bodies.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertTrue((messages.last?["content"] as? String ?? "").contains("изменился"))
    }

    func testCreateDoesNotOverwriteFileCreatedDuringApproval() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("new.txt")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentMockProtocol.self]
        AgentMockProtocol.requests = []
        AgentMockProtocol.bodies = []
        AgentMockProtocol.action = "create"
        defer { AgentMockProtocol.action = "replace" }
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!,
            model: "test", session: URLSession(configuration: configuration))
        let agent = LiveAgent(workspace: workspace, client: client, onEvent: { _ in }, approve: { _ in
            try? "user".write(to: file, atomically: true, encoding: .utf8)
            return true
        })
        _ = try await agent.run(task: "Create the file")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user")
        let data = try XCTUnwrap(AgentMockProtocol.bodies.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertTrue((messages.last?["content"] as? String ?? "").contains("уже существует"))
    }

    func testModelToolResultRoundTrip() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("file.txt")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentMockProtocol.self]
        AgentMockProtocol.requests = []
        AgentMockProtocol.bodies = []
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!,
            model: "test", session: URLSession(configuration: configuration))
        let capture = ConversationCapture()
        let agent = LiveAgent(workspace: workspace, client: client, onEvent: { event in
            if case let .conversation(messages) = event { await capture.set(messages) }
        }, approve: { _ in
            let checkpoint = await capture.get()
            guard case let .string(status) = checkpoint.last?["content"] else {
                XCTFail("Expected checkpoint before approval")
                return false
            }
            XCTAssertTrue(status.contains("Результат неизвестен"))
            return true
        })
        let result = try await agent.run(task: "Change the file")
        XCTAssertEqual(result, "Done")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        XCTAssertEqual(AgentMockProtocol.requests.count, 2)
        let data = try XCTUnwrap(AgentMockProtocol.bodies.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["tool_call_id"] as? String, "call-1")
        let previous = await capture.get()
        XCTAssertEqual(previous.last?["role"], .string("assistant"))
        _ = try await agent.run(task: "Continue", history: previous)
        let replay = try XCTUnwrap(AgentMockProtocol.bodies.last)
        let replayBody = try XCTUnwrap(JSONSerialization.jsonObject(with: replay) as? [String: Any])
        let replayMessages = try XCTUnwrap(replayBody["messages"] as? [[String: Any]])
        XCTAssertTrue(replayMessages.contains { $0["tool_call_id"] as? String == "call-1" })
    }

    func testInterruptedBatchPreservesCompletedAndMarksRemainingTools() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("file.txt")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentMockProtocol.self]
        AgentMockProtocol.requests = []
        AgentMockProtocol.bodies = []
        AgentMockProtocol.action = "batch"
        defer { AgentMockProtocol.action = "replace" }
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!,
            model: "test", session: URLSession(configuration: configuration))
        let capture = ConversationCapture()
        let agent = LiveAgent(workspace: workspace, client: client, onEvent: { event in
            if case let .conversation(messages) = event { await capture.set(messages) }
            if case .toolFinished = event { withUnsafeCurrentTask { $0?.cancel() } }
        }, approve: { _ in true })
        do {
            _ = try await agent.run(task: "Change the file")
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        let messages = await capture.get()
        let results = messages.filter { $0["role"] == .string("tool") }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0]["tool_call_id"], .string("call-1"))
        XCTAssertEqual(results[1]["tool_call_id"], .string("call-2"))
        guard case let .string(description) = results[1]["content"] else {
            return XCTFail("Missing interruption status")
        }
        XCTAssertTrue(description.contains("прервано"))
    }
}

private actor ConversationCapture {
    private var value: [[String: JSONValue]] = []
    func set(_ messages: [[String: JSONValue]]) { value = messages }
    func get() -> [[String: JSONValue]] { value }
}

private final class AgentMockProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    static var action = "replace"
    static var editPath = "file.txt"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let body = request.httpBody {
            Self.bodies.append(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            Self.bodies.append(data)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let content: String
        if Self.requests.count == 1 && Self.action == "batch" {
            content = #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"replace_text","arguments":"{\"path\":\"file.txt\",\"old\":\"old\",\"new\":\"new\"}"}},{"index":1,"id":"call-2","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"file.txt\"}"}}]},"finish_reason":"tool_calls"}]}"#
        } else if Self.requests.count == 1 && Self.action == "create" {
            content = #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"create_file","arguments":"{\"path\":\"new.txt\",\"contents\":\"agent\"}"}}]},"finish_reason":"tool_calls"}]}"#
        } else if Self.requests.count == 1 {
            content = #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"replace_text","arguments":"{\"path\":\"\#(Self.editPath)\",\"old\":\"old\",\"new\":\"new\"}"}}]},"finish_reason":"tool_calls"}]}"#
        } else {
            content = #"data: {"choices":[{"index":0,"delta":{"content":"Done"},"finish_reason":"stop"}]}"#
        }
        client?.urlProtocol(self, didLoad: Data((content + "\n\ndata: [DONE]\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
