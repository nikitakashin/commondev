import Foundation
import XCTest
@testable import AgentCore

final class LiveAgentRetryTests: XCTestCase {
    private func client(_ mode: TimeoutProtocol.Mode) -> OpenAICompatibleClient {
        TimeoutProtocol.mode = mode
        TimeoutProtocol.count = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimeoutProtocol.self]
        return OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!,
                                      model: "test", session: URLSession(configuration: configuration))
    }

    func testTimeoutBeforeDeltaRetriesOnceWithinBudget() async throws {
        let recorder = RetryEvents()
        let agent = LiveAgent(workspace: FileManager.default.temporaryDirectory, client: client(.before),
                              onEvent: { await recorder.record($0) }, approve: { _ in false }, maxModelCalls: 2)
        let answer = try await agent.run(task: "test")
        XCTAssertEqual(answer, "Done")
        XCTAssertEqual(TimeoutProtocol.count, 2)
        let notices = await recorder.notices
        let requests = await recorder.requests
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(requests, 2)
    }

    func testTimeoutAfterTextDoesNotRetry() async throws {
        let recorder = RetryEvents()
        let agent = LiveAgent(workspace: FileManager.default.temporaryDirectory, client: client(.text),
                              onEvent: { await recorder.record($0) }, approve: { _ in false })
        do {
            _ = try await agent.run(task: "test")
            XCTFail("Expected a timeout")
        } catch {}
        XCTAssertEqual(TimeoutProtocol.count, 1)
        let notices = await recorder.notices
        XCTAssertTrue(notices.isEmpty)
    }

    func testTimeoutAfterPartialToolDeltaDoesNotRetryOrExecute() async throws {
        let recorder = RetryEvents()
        let agent = LiveAgent(workspace: FileManager.default.temporaryDirectory, client: client(.tool),
                              onEvent: { await recorder.record($0) }, approve: { _ in
            XCTFail("An incomplete tool call must not be executed")
            return false
        })
        do {
            _ = try await agent.run(task: "test")
            XCTFail("Expected a timeout")
        } catch {}
        XCTAssertEqual(TimeoutProtocol.count, 1)
        let notices = await recorder.notices
        XCTAssertTrue(notices.isEmpty)
    }

    func testTimeoutInUnfinishedSSEFrameDoesNotRetry() async throws {
        let agent = LiveAgent(workspace: FileManager.default.temporaryDirectory, client: client(.partialFrame),
                              onEvent: { _ in }, approve: { _ in false })
        do {
            _ = try await agent.run(task: "test")
            XCTFail("Expected a timeout")
        } catch {}
        XCTAssertEqual(TimeoutProtocol.count, 1)
    }

    func testNoRetryWhenSharedBudgetExhausted() async throws {
        let budget = ModelRequestBudget(maximum: 1)
        let agent = LiveAgent(workspace: FileManager.default.temporaryDirectory, client: client(.before),
                              onEvent: { _ in }, approve: { _ in false }, maxModelCalls: 3, requestBudget: budget)
        do {
            _ = try await agent.run(task: "test")
            XCTFail("Expected budget exhaustion")
        } catch {}
        XCTAssertEqual(TimeoutProtocol.count, 1)
    }
}

private actor RetryEvents {
    private(set) var notices: [String] = []
    private(set) var requests = 0
    func record(_ event: LiveAgentEvent) {
        if case let .notice(value) = event { notices.append(value) }
        if case .modelRequest = event { requests += 1 }
    }
}

private final class TimeoutProtocol: URLProtocol {
    enum Mode { case before, text, tool, partialFrame }
    static var mode: Mode = .before
    static var count = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        if Self.count > 1 {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let data = #"data: {"choices":[{"index":0,"delta":{"content":"Done"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
            client?.urlProtocol(self, didLoad: Data(data.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if Self.mode != .before {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let data: String
            if Self.mode == .text {
                data = #"data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}"#
            } else if Self.mode == .tool {
                data = #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"run_command","arguments":"{"}}]}}]}"#
            } else {
                client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[".utf8))
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                }
                return
            }
            client?.urlProtocol(self, didLoad: Data((data + "\n\n").utf8))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }
    override func stopLoading() {}
}
