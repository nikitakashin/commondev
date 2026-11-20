import Foundation
import XCTest
import AgentCore
@testable import CommondevApp

@MainActor
final class ReasoningEffortTests: XCTestCase {
    func testCustomEndpointSendsEffortOnlyWithOptInAndResetsWhenModelChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReasoningProtocol.self]
        let session = URLSession(configuration: config)
        let model = AppModel(storageRoot: root.appendingPathComponent("storage")) {
            OpenAICompatibleClient(endpoint: $0, model: $1, apiKey: $2, session: session)
        }
        let chat = ChatSession(name: "test", projectPath: root.path)
        model.sessions = [chat]
        model.selectSession(chat.id)
        model.useFreeModel = false
        model.endpoint = "https://example.test/v1/chat/completions"
        model.modelName = "test"
        model.supportsReasoningEffort = false
        model.setWorkMode(.xhigh)
        model.draft = "first"
        model.send()
        try await waitForReply(model)
        XCTAssertNil(ReasoningProtocol.payload?["reasoning_effort"])

        model.supportsReasoningEffort = true
        model.draft = "second"
        model.send()
        try await waitForReply(model)
        XCTAssertEqual(ReasoningProtocol.payload?["reasoning_effort"] as? String, "high")

        model.modelName = "different-model"
        XCTAssertFalse(model.supportsReasoningEffort)
        model.supportsReasoningEffort = true
        model.endpoint = "https://other.test/v1/chat/completions"
        XCTAssertFalse(model.supportsReasoningEffort)
    }

    private func waitForReply(_ model: AppModel) async throws {
        for _ in 0..<100 {
            if !model.isRunning { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Model request did not finish")
    }
}

private final class ReasoningProtocol: URLProtocol {
    static var payload: [String: Any]?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            data = result
        }
        Self.payload = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = #"data: {"choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
