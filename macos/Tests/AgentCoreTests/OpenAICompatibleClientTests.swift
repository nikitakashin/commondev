import Foundation
import XCTest
@testable import AgentCore

final class OpenAICompatibleClientTests: XCTestCase {
    private func client(body: String, status: Int = 200) -> OpenAICompatibleClient {
        MockProtocol.requestCount = 0
        MockProtocol.responseBody = body
        MockProtocol.status = status
        MockProtocol.routedVia = "mock/model"
        MockProtocol.responseURL = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        return OpenAICompatibleClient(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "auto:fast", apiKey: "test-key", session: URLSession(configuration: configuration)
        )
    }

    func testDirectEndpointIdentityDoesNotInventProviderOrModelForAutomaticRouter() async throws {
        let body = "data: {\"model\":\"actual\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let automatic = client(body: body)
        MockProtocol.routedVia = nil
        let withoutFallback = try await automatic.complete(messages: [], tools: [])
        XCTAssertNil(withoutFallback.routedVia, "Automatic routing must require a provider header")
        XCTAssertEqual(withoutFallback.actualModel, "actual")

        let direct = automatic.identifyingDirectEndpoint().enablingReasoningEffort(.high).selectingModel("fixed")
        let first = try await direct.complete(messages: [], tools: [])
        let route = try XCTUnwrap(first.routedVia)
        XCTAssertTrue(route.hasPrefix("endpoint-sha256:"))
        XCTAssertFalse(route.contains("example.test"))
        XCTAssertEqual(first.actualModel, "actual")
        let again = try await direct.complete(messages: [], tools: [])
        XCTAssertEqual(again.routedVia, route)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        let other = OpenAICompatibleClient(endpoint: URL(string: "https://other.test/chat")!, model: "fixed",
                                           session: URLSession(configuration: configuration)).identifyingDirectEndpoint()
        let otherResponse = try await other.complete(messages: [], tools: [])
        XCTAssertNotEqual(otherResponse.routedVia, route)

        MockProtocol.responseURL = URL(string: "https://redirected.test/chat")!
        let redirected = try await direct.complete(messages: [], tools: [])
        XCTAssertNotEqual(redirected.routedVia, route, "The responding endpoint, not only the configured URL, must be tracked")
        MockProtocol.responseURL = nil

        MockProtocol.routedVia = "real-route"
        let withHeader = try await direct.complete(messages: [], tools: [])
        XCTAssertEqual(withHeader.routedVia, "real-route", "A reported route takes precedence")
        MockProtocol.routedVia = nil
        MockProtocol.responseBody = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let noModel = try await direct.complete(messages: [], tools: [])
        XCTAssertNil(noModel.actualModel, "The configured alias must not be claimed as the actual model")
    }

    func testStreamingInterleavedCallsAndText() async throws {
        let body = """
        data: {"choices":[{"index":0,"delta":{"content":"Проверяю ","tool_calls":[{"index":1,"id":"call-b","type":"function","function":{"name":"read","arguments":"{\\"path\\":\\""}},{"index":0,"id":"call-a","type":"function","function":{"name":"run","arguments":"{\\"command\\":\\""}}]}}]}

        data: {"choices":[{"index":0,"delta":{"content":"проект","tool_calls":[{"index":0,"function":{"arguments":"swift test\\"}"}},{"index":1,"function":{"arguments":"а.swift\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        \n
        """
        let client = client(body: body + "\n\n")
        var chunks: [String] = []
        let response = try await client.complete(messages: [["role": .string("user"), "content": .string("test")]], tools: []) { chunks.append($0) }
        XCTAssertEqual(chunks, ["Проверяю ", "проект"])
        XCTAssertEqual(response.text, "Проверяю проект")
        XCTAssertEqual(response.toolCalls.map(\.id), ["call-a", "call-b"])
        XCTAssertEqual(response.toolCalls.map(\.name), ["run", "read"])
        XCTAssertEqual(response.toolCalls[1].argumentsJSON, "{\"path\":\"а.swift\"}")
        XCTAssertEqual(response.routedVia, "mock/model")
        let request = try XCTUnwrap(MockProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testInterruptedStreamDoesNotYieldCalls() async throws {
        let body = "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"function\":{\"name\":\"run\",\"arguments\":\"{\"}}]}}]}\n\n"
        do {
            _ = try await client(body: body).complete(messages: [], tools: [])
            XCTFail("Truncated stream must not execute a partial call")
        } catch OpenAIClientError.incompleteStream {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRateLimitReportedWithoutRetry() async throws {
        do {
            _ = try await client(body: "rate limited", status: 429).complete(messages: [], tools: [])
            XCTFail("Expected HTTP error")
        } catch OpenAIClientError.http(let status, _) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(MockProtocol.requestCount, 1)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancelledRequestDoesNotReturnAResponse() async throws {
        let client = client(body: "")
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.complete(messages: [], tools: [])
        }
        do {
            _ = try await request.value
            XCTFail("A cancelled request must not return a response")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    func testReasoningEffortRequiresExplicitCapability() async throws {
        let body = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let defaultClient = client(body: body)
        _ = try await defaultClient.complete(messages: [], tools: [], reasoningEffort: .high)
        var request = try XCTUnwrap(MockProtocol.lastBody)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertNil(payload["reasoning_effort"])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        let capableClient = OpenAICompatibleClient(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!, model: "known",
            session: URLSession(configuration: configuration), supportsReasoningEffort: true
        )
        _ = try await capableClient.complete(messages: [], tools: [], reasoningEffort: .high)
        request = try XCTUnwrap(MockProtocol.lastBody)
        payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertEqual(payload["reasoning_effort"] as? String, "high")

        let configured = defaultClient.enablingReasoningEffort(.medium).selectingModel("other")
        _ = try await configured.complete(messages: [], tools: [])
        request = try XCTUnwrap(MockProtocol.lastBody)
        payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "other")
        XCTAssertEqual(payload["reasoning_effort"] as? String, "medium")
    }
}

private final class MockProtocol: URLProtocol {
    static var responseBody = ""
    static var status = 200
    static var lastRequest: URLRequest?
    static var requestCount = 0
    static var lastBody: Data?
    static var routedVia: String? = "mock/model"
    static var responseURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody
        if Self.lastBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            Self.lastBody = bytes
        }
        Self.requestCount += 1
        var headers = ["Content-Type": "text/event-stream"]
        if let routedVia = Self.routedVia { headers["X-Routed-Via"] = routedVia }
        let response = HTTPURLResponse(url: Self.responseURL ?? request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Deliberately fragment UTF-8 and event boundaries.
        for byte in Self.responseBody.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
