import Foundation
import XCTest
import AgentCore
@testable import CommondevApp

@MainActor
final class ModelSettingsTests: XCTestCase {
    func testDraftIsIsolatedAndSavingValidatesBeforeApplying() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "commondev-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(storageRoot: root)
        app.useFreeModel = false
        app.endpoint = "https://old.example/v1/chat/completions"
        app.modelName = "old-model"
        app.apiKey = "old-key"
        app.supportsReasoningEffort = true

        var draft = app.modelSettingsDraft()
        draft.readKey = { _ in "" }
        draft.endpoint = "not-a-url"
        draft.modelName = "new-model"
        draft.apiKey = "new-key"
        XCTAssertFalse(draft.supportsReasoningEffort)
        XCTAssertEqual(app.endpoint, "https://old.example/v1/chat/completions")
        XCTAssertEqual(app.apiKey, "old-key")
        app.showSettings = true
        var savedKey: String?
        app.saveSettings(draft, defaults: defaults) { key, _ in savedKey = key }
        XCTAssertNil(savedKey)
        XCTAssertTrue(app.showSettings)
        XCTAssertEqual(app.modelName, "old-model")
        XCTAssertTrue(app.supportsReasoningEffort)

        draft.endpoint = "https://new.example/v1/chat/completions"
        XCTAssertEqual(draft.apiKey, "")
        draft.apiKey = "new-key"
        draft.supportsReasoningEffort = true
        app.saveSettings(draft, defaults: defaults) { _, _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertEqual(app.endpoint, "https://old.example/v1/chat/completions")
        XCTAssertEqual(app.apiKey, "old-key")
        XCTAssertTrue(app.showSettings)

        app.saveSettings(draft, defaults: defaults) { key, _ in savedKey = key }
        XCTAssertEqual(savedKey, "new-key")
        XCTAssertEqual(app.endpoint, draft.endpoint)
        XCTAssertEqual(app.modelName, "new-model")
        XCTAssertTrue(app.supportsReasoningEffort)
        XCTAssertFalse(app.showSettings)
        XCTAssertEqual(defaults.string(forKey: "endpoint"), draft.endpoint)
    }

    func testEndpointDraftSelectsKeysByOrigin() {
        let origin = KeychainStore.account(for: "https://A.example:443/one")
        XCTAssertEqual(origin, KeychainStore.account(for: "https://a.example/two"))
        var draft = ModelSettingsDraft(useFreeModel: false, endpoint: "https://a.example/one",
                                       modelName: "model", apiKey: "first", supportsReasoningEffort: true,
                                       readKey: { $0 == origin ? "first" : "" })
        draft.endpoint = "https://a.example/two"
        XCTAssertEqual(draft.apiKey, "first")
        for address in ["http://a.example", "https://a.example:444", "https://b.example"] {
            draft.endpoint = address
            XCTAssertEqual(draft.apiKey, "")
            draft.endpoint = "https://A.example:443/three"
            XCTAssertEqual(draft.apiKey, "first")
        }
    }

    func testRequestUsesConnectionSelectedWhenSent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsTestProtocol.self]
        let session = URLSession(configuration: config)
        var selectedURL: URL?
        var selectedModel: String?
        var selectedKey: String?
        let app = AppModel(storageRoot: root.appendingPathComponent("storage")) { url, model, key in
            selectedURL = url
            selectedModel = model
            selectedKey = key
            return OpenAICompatibleClient(endpoint: url, model: model, apiKey: key, session: session)
        }
        let chat = ChatSession(name: "fixture", projectPath: root.path)
        app.sessions = [chat]
        app.selectSession(chat.id)
        app.useFreeModel = false
        app.endpoint = "https://old.example/v1/chat/completions"
        app.modelName = "old-model"
        app.apiKey = "old-key"
        app.draft = "hello"
        app.send()
        app.endpoint = "https://new.example/v1/chat/completions"
        app.modelName = "new-model"
        app.apiKey = "new-key"
        for _ in 0..<100 {
            if !app.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(app.isRunning)
        XCTAssertEqual(selectedURL?.absoluteString, "https://old.example/v1/chat/completions")
        XCTAssertEqual(selectedModel, "old-model")
        XCTAssertEqual(selectedKey, "old-key")
    }
}

private final class SettingsTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = #"data: {"choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
