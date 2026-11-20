import Foundation
import XCTest
@testable import CommondevApp
import AgentCore

@MainActor
final class MessageQueueTests: XCTestCase {
    private func makeModel(root: URL) throws -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueModelProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = AppModel(storageRoot: root.appendingPathComponent("storage")) {
            OpenAICompatibleClient(endpoint: $0, model: $1, apiKey: $2, session: session)
        }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let chat = ChatSession(name: "test", projectPath: project.path)
        model.sessions = [chat]
        model.selectSession(chat.id)
        model.useFreeModel = false
        model.endpoint = "https://example.test/v1/chat/completions"
        model.modelName = "test"
        return model
    }

    func testRouteChangePausesQueueAcrossRestartUntilUserChooses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        model.draft = "first"
        model.send()
        model.draft = "second"
        model.send()
        model.endpoint = "https://other.example/chat"
        for _ in 0..<100 where model.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(model.hasQueuedMessages)
        model.resumeQueue()
        XCTAssertFalse(model.isRunning)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QueueModelProtocol.self]
        let network = URLSession(configuration: config)
        let reopened = AppModel(storageRoot: root.appendingPathComponent("storage")) {
            OpenAICompatibleClient(endpoint: $0, model: $1, apiKey: $2, session: network)
        }
        reopened.useFreeModel = false
        reopened.endpoint = model.endpoint
        reopened.modelName = model.modelName
        reopened.resumeQueue()
        XCTAssertFalse(reopened.isRunning)
        reopened.endpoint = "https://example.test/v1/chat/completions"
        XCTAssertFalse(reopened.queueNeedsConnectionChoice)
        reopened.modelName = "different-model"
        XCTAssertTrue(reopened.queueNeedsConnectionChoice)
        reopened.sendFirstQueuedMessage()
        XCTAssertTrue(reopened.isRunning)
        XCTAssertFalse(reopened.hasQueuedMessages)
        for _ in 0..<100 where reopened.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(reopened.selectedSession?.messages.filter { $0.role == "assistant" }.count, 2)
    }

    func testOversizedDraftIsEditableAndDoesNotPoisonNextRequestOrQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        let oversized = String(repeating: "я", count: 49_000)
        model.draft = oversized
        model.send()
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.draft, oversized)
        XCTAssertTrue(model.selectedSession?.messages.isEmpty == true)
        XCTAssertNil(model.selectedSession?.conversation)
        model.draft = "short"
        model.send()
        XCTAssertTrue(model.isRunning)
        model.draft = oversized
        model.send()
        XCTAssertFalse(model.hasQueuedMessages)
        XCTAssertEqual(model.draft, oversized)
        for _ in 0..<100 where model.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.selectedSession?.conversation?.last?["content"], .string("done"))
    }

    func testManualTitleAndLegacyPlaceholderSurviveOpeningHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeModel(root: root)
        app.newChat(inProject: nil)
        let id = try XCTUnwrap(app.selectedID)
        app.renameChat(id, to: ChatTitle.placeholder)
        app.draft = "Проверь историю"
        app.send()
        for _ in 0..<100 where app.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        let saved = try XCTUnwrap(try SessionStore(root: root.appendingPathComponent("storage")).load().first)
        XCTAssertEqual(saved.displayName, ChatTitle.placeholder)
        XCTAssertEqual(saved.manuallyNamed, true)
        let legacy = ChatSession(name: ChatTitle.placeholder, messages: saved.messages)
        XCTAssertEqual(legacy.displayName, "Проверь историю")
    }

    func testLegacyQueueRequiresExplicitRouteAndCanBeReturnedToDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeModel(root: root)
        app.sessions[0].messages.append(ChatMessage(role: "user", text: "pending", queued: true))
        app.resumeQueue()
        XCTAssertFalse(app.isRunning)
        XCTAssertTrue(app.queueNeedsConnectionChoice)
        app.restoreFirstQueuedDraft()
        XCTAssertEqual(app.draft, "pending")
        XCTAssertFalse(app.hasQueuedMessages)
    }

    func testQueuedMessageRunsAfterFirstResponseAndPreservesDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        model.draft = "first"
        model.send()
        model.draft = "second"
        model.send()
        model.draft = "unsent draft"
        XCTAssertTrue(model.hasQueuedMessages)
        XCTAssertTrue(model.selectedSession?.messages.contains(where: { $0.text == "second" && $0.queued == true }) == true)

        for _ in 0..<100 {
            if !model.isRunning && !model.hasQueuedMessages { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.hasQueuedMessages)
        XCTAssertEqual(model.draft, "unsent draft")
        let messages = try XCTUnwrap(model.selectedSession?.messages)
        XCTAssertEqual(messages.filter { $0.role == "user" }.map(\.text), ["first", "second"])
        XCTAssertEqual(messages.filter { ["user", "assistant"].contains($0.role) }.map(\.text),
                       ["first", "done", "second", "done"])
    }

    func testStopKeepsQueueForManualResumeAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        model.draft = "first"
        model.send()
        model.draft = "second"
        model.send()
        model.stop()
        for _ in 0..<100 {
            if !model.isRunning { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.hasQueuedMessages)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(model.hasQueuedMessages)
        XCTAssertFalse(model.isRunning)
        let restarted = AppModel(storageRoot: root.appendingPathComponent("storage"))
        XCTAssertTrue(restarted.hasQueuedMessages)
        XCTAssertEqual(restarted.selectedSession?.messages.last(where: { $0.queued == true })?.text, "second")
        model.resumeQueue()
        for _ in 0..<100 {
            if !model.isRunning && !model.hasQueuedMessages { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(model.hasQueuedMessages)
        XCTAssertTrue(model.selectedSession?.messages.contains(where: { $0.role == "assistant" && $0.text == "done" }) == true)
    }

    func testStartedQueuedMessageIsRestoredInVisibleAndModelHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        model.draft = "first"
        model.send()
        model.draft = "queued request"
        model.send()
        model.stop()
        for _ in 0..<100 {
            if !model.isRunning { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(model.hasQueuedMessages)

        // No suspension between starting the queued request and reading the
        // stored file: this is the state available if the app closes now.
        model.resumeQueue()
        let restarted = AppModel(storageRoot: root.appendingPathComponent("storage"))
        let restored = try XCTUnwrap(restarted.selectedSession)
        XCTAssertEqual(restored.messages.filter { $0.text == "queued request" }.count, 1)
        XCTAssertFalse(restored.messages.contains { $0.text == "queued request" && $0.queued == true })
        XCTAssertEqual(restored.conversation?.last?["content"], .string("queued request"))
        XCTAssertEqual(restored.conversation?.last?["role"], .string("user"))
        model.stop()
        for _ in 0..<100 {
            if !model.isRunning { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    func testUnreadableHistoryIsNeverOverwrittenAndAgentDoesNotStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = root.appendingPathComponent("sessions.json")
        let original = Data("{ invalid but recoverable history".utf8)
        try original.write(to: history)

        let model = AppModel(storageRoot: root)
        XCTAssertNotNil(model.error)
        let session = ChatSession(name: "test", projectPath: root.path)
        model.sessions = [session]
        model.selectSession(session.id)
        model.setWorkMode(.high)
        model.draft = "request"
        model.send()

        XCTAssertEqual(try Data(contentsOf: history), original)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.draft, "request")
        XCTAssertTrue(model.error?.contains(history.path) == true)
    }

    func testAgentDoesNotStartWhenInitialMessageCannotBeSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = try makeModel(root: root)
        // A file where the storage directory should be makes every history write fail.
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("storage"))
        model.draft = "important request"
        model.send()
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.draft, "important request")
        XCTAssertFalse(model.selectedSession?.messages.contains(where: { $0.role == "user" }) ?? true)
        XCTAssertTrue(model.error?.contains("Не удалось сохранить историю") == true)
    }

    func testFailedCheckpointStopsBeforeRequestingPermissionForSideEffect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CheckpointToolProtocol.self]
        let network = URLSession(configuration: configuration)
        let storage = root.appendingPathComponent("storage")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let model = AppModel(storageRoot: storage) {
            OpenAICompatibleClient(endpoint: $0, model: $1, apiKey: $2, session: network)
        }
        let chat = ChatSession(name: "test", projectPath: project.path)
        model.sessions = [chat]
        model.selectSession(chat.id)
        model.useFreeModel = false
        model.endpoint = "https://example.test/v1/chat/completions"
        model.modelName = "test"
        model.draft = "create a file"
        model.send()
        XCTAssertTrue(model.isRunning)

        // Sabotage storage after the initial request is committed, before the
        // delayed model response asks to create a file.
        let history = storage.appendingPathComponent("Sessions").appendingPathComponent(chat.id.uuidString + ".json")
        try FileManager.default.moveItem(at: history, to: storage.appendingPathComponent("saved-history.json"))
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        for _ in 0..<100 {
            if !model.isRunning { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.approval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("written.txt").path))
        XCTAssertFalse(model.selectedSession?.messages.contains(where: { $0.text.contains("create_file") }) ?? true)
        XCTAssertTrue(model.error?.contains("Не удалось сохранить историю") == true)
    }
}

private final class QueueModelProtocol: URLProtocol {
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.stopped else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = #"data: {"model":"test","choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stopped = true }
}

private final class CheckpointToolProtocol: URLProtocol {
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.stopped else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"create_file","arguments":"{\"path\":\"written.txt\",\"contents\":\"bad\"}"}}]},"finish_reason":"tool_calls"}]}"# + "\n\ndata: [DONE]\n\n"
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stopped = true }
}
