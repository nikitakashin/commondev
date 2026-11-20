import XCTest
import Foundation
import AgentCore
@testable import CommondevApp

@MainActor
final class HarnessSupportTests: XCTestCase {
    func testDirectEndpointWithoutRouteHeaderRecordsItsIdentityForHarness() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouteTrackingProtocol.self]
        RouteTrackingProtocol.count = 2
        RouteTrackingProtocol.includeRouteHeader = false
        defer { RouteTrackingProtocol.includeRouteHeader = true }
        let session = URLSession(configuration: configuration)
        let app = AppModel(storageRoot: root.appendingPathComponent("storage")) {
            OpenAICompatibleClient(endpoint: $0, model: $1, apiKey: $2, session: session)
        }
        let chat = ChatSession(name: "fixture", projectPath: root.path)
        app.sessions = [chat]
        app.selectSession(chat.id)
        app.useFreeModel = false
        app.endpoint = "https://direct.example.test/chat"
        app.modelName = "configured"
        app.draft = "Inspect"
        app.send()
        for _ in 0..<200 {
            if !app.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(app.isRunning)
        XCTAssertEqual(app.harness.actualModel, "model-c")
        XCTAssertTrue(app.harness.expectedRoute.hasPrefix("endpoint-sha256:"))
        XCTAssertTrue(app.selectedSession?.messages.contains { $0.text == "Модель: Свой endpoint" } == true)
    }

    func testAgentDiscardsChangedRouteAndNextRequestStartsFresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouteTrackingProtocol.self]
        RouteTrackingProtocol.count = 0
        let session = URLSession(configuration: configuration)
        let app = AppModel(storageRoot: root.appendingPathComponent("storage")) {
            OpenAICompatibleClient(endpoint: $0, model: $1, apiKey: $2, session: session)
        }
        let chat = ChatSession(name: "fixture", projectPath: root.path)
        app.sessions = [chat]
        app.selectSession(chat.id)
        app.useFreeModel = false
        app.endpoint = "https://example.test/chat"
        app.modelName = "auto"
        app.harness.beginRouteTracking()
        app.harness.observeRoute(model: "stale", provider: "stale")

        app.draft = "Inspect files"
        app.send()
        for _ in 0..<200 {
            if !app.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(app.isRunning)
        XCTAssertEqual(RouteTrackingProtocol.count, 2)
        XCTAssertTrue(app.harness.actualModel.isEmpty)
        XCTAssertTrue(app.harness.expectedRoute.isEmpty)

        app.draft = "Another request"
        app.send()
        for _ in 0..<200 {
            if !app.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(app.isRunning)
        XCTAssertEqual(RouteTrackingProtocol.count, 3)
        XCTAssertEqual(app.harness.actualModel, "model-c")
        XCTAssertEqual(app.harness.expectedRoute, "provider-c")
    }

    func testRouteIsFreshForEachRequestAndInvalidatedOnChangesOrMissingIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = HarnessSupport(storageRoot: root.appendingPathComponent("storage"))
        support.load(project: project)

        support.beginRouteTracking()
        support.observeRoute(model: "model-a", provider: "provider-a")
        support.observeRoute(model: "model-a", provider: "provider-a")
        XCTAssertEqual(support.actualModel, "model-a")
        XCTAssertEqual(support.expectedRoute, "provider-a")
        support.observeRoute(model: "model-b", provider: "provider-a")
        XCTAssertTrue(support.actualModel.isEmpty)
        XCTAssertTrue(support.expectedRoute.isEmpty)
        support.observeRoute(model: "model-a", provider: "provider-a")
        XCTAssertTrue(support.actualModel.isEmpty, "A later response must not hide a change within the request")

        support.beginRouteTracking()
        support.observeRoute(model: "model-b", provider: "provider-b")
        XCTAssertEqual(support.actualModel, "model-b")
        XCTAssertEqual(support.expectedRoute, "provider-b")
        support.observeRoute(model: "model-b", provider: nil)
        XCTAssertTrue(support.actualModel.isEmpty)
        XCTAssertTrue(support.expectedRoute.isEmpty)
        support.observeRoute(model: "model-b", provider: "provider-b")
        XCTAssertTrue(support.expectedRoute.isEmpty, "A missing identity must invalidate the whole request")
    }

    func testVerificationExpiresAfterApprovedChangesOrCommands() {
        var tracker = TestVerificationTracker()
        tracker.started(id: "test", name: "run_command")
        tracker.approved(.command(command: "swift test", cwd: "/project"))
        tracker.finished(id: "test", result: "OK\nКод завершения: 0")
        XCTAssertEqual(tracker.verifiedCommand, "swift test")

        // A rejected edit never reaches approved(), so it cannot invalidate the result.
        tracker.started(id: "edit", name: "replace_text")
        tracker.finished(id: "edit", result: "Правка отклонена пользователем.")
        XCTAssertEqual(tracker.verifiedCommand, "swift test")

        tracker.approved(.edit(path: "source.swift", diff: "diff"))
        XCTAssertNil(tracker.verifiedCommand)
        tracker.started(id: "retest", name: "run_command")
        tracker.approved(.command(command: "swift test", cwd: "/project"))
        tracker.finished(id: "retest", result: "OK\nКод завершения: 0")
        XCTAssertEqual(tracker.verifiedCommand, "swift test")
        tracker.started(id: "other", name: "run_command")
        tracker.approved(.command(command: "make generate", cwd: "/project"))
        tracker.finished(id: "other", result: "Код завершения: 0")
        XCTAssertNil(tracker.verifiedCommand)
    }

    func testCannotSwitchProjectWhileAgentIsRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(storageRoot: root.appendingPathComponent("storage"))
        let firstSession = ChatSession(name: "first", projectPath: first.path)
        let secondSession = ChatSession(name: "second", projectPath: second.path)
        model.sessions = [firstSession, secondSession]
        model.selectSession(firstSession.id)
        model.harness.setEnabled(true)
        model.isRunning = true
        model.selectSession(secondSession.id)
        model.selectSession(nil)
        XCTAssertEqual(model.selectedID, firstSession.id)
        XCTAssertTrue(model.harness.enabled)

        model.isRunning = false
        model.selectSession(secondSession.id)
        XCTAssertEqual(model.selectedID, secondSession.id)
        XCTAssertFalse(model.harness.enabled)
        model.selectSession(firstSession.id)
        XCTAssertTrue(model.harness.enabled)
    }

    func testCollectsSuccessfulTasksAndKeepsSeparateProjectSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("answer.txt")
        try "before first".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let support = HarnessSupport(storageRoot: root.appendingPathComponent("storage"))
        support.load(project: project)
        support.setEnabled(true)
        let first = try await support.captureBefore(project: project)
        try "before second".write(to: file, atomically: true, encoding: .utf8)
        support.recordCompletedSample(snapshot: first, project: project, prompt: "first issue", testCommand: "swift test")
        XCTAssertTrue(support.status.contains("1 из 2"))

        let second = try await support.captureBefore(project: project)
        try "after second".write(to: file, atomically: true, encoding: .utf8)
        support.recordCompletedSample(snapshot: second, project: project, prompt: "second issue", testCommand: "swift test")
        XCTAssertNotEqual(support.trainingPath, support.heldOutPath)
        XCTAssertEqual(support.prompt, "first issue")
        XCTAssertEqual(support.heldOutPrompt, "second issue")
        XCTAssertEqual(try String(contentsOfFile: support.trainingPath + "/answer.txt", encoding: .utf8), "before first")
        XCTAssertEqual(try String(contentsOfFile: support.heldOutPath + "/answer.txt", encoding: .utf8), "before second")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after second")
    }

    func testEnabledStatePersistsPerProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstProject = root.appendingPathComponent("first")
        let secondProject = root.appendingPathComponent("second")
        let storage = root.appendingPathComponent("storage")
        try FileManager.default.createDirectory(at: firstProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let support = HarnessSupport(storageRoot: storage)
        support.load(project: firstProject)
        XCTAssertFalse(support.enabled)
        support.setEnabled(true)
        support.load(project: secondProject)
        XCTAssertFalse(support.enabled)
        support.load(project: firstProject)
        XCTAssertTrue(support.enabled)

        let restarted = HarnessSupport(storageRoot: storage)
        restarted.load(project: firstProject)
        XCTAssertTrue(restarted.enabled)
        restarted.setEnabled(false)
        let afterDisable = HarnessSupport(storageRoot: storage)
        afterDisable.load(project: firstProject)
        XCTAssertFalse(afterDisable.enabled)
    }
}

private final class RouteTrackingProtocol: URLProtocol {
    static var count = 0
    static var includeRouteHeader = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        let model = Self.count == 1 ? "model-a" : Self.count == 2 ? "model-b" : "model-c"
        let provider = Self.count == 1 ? "provider-a" : Self.count == 2 ? "provider-b" : "provider-c"
        var headers = ["Content-Type": "text/event-stream"]
        if Self.includeRouteHeader { headers["X-Routed-Via"] = provider }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let delta = Self.count == 1
            ? #"{"tool_calls":[{"index":0,"id":"find-1","type":"function","function":{"name":"find_files","arguments":"{\"pattern\":\"*\"}"}}]}"#
            : #"{"content":"done"}"#
        let body = "data: {\"model\":\"\(model)\",\"choices\":[{\"index\":0,\"delta\":\(delta),\"finish_reason\":\"\(Self.count == 1 ? "tool_calls" : "stop")\"}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
