import XCTest
import Foundation
import AgentCore
@testable import HarnessIntegration
import HarnessCore

final class LiveHarnessExecutorTests: XCTestCase {
    func testDirectEndpointWithoutRouteHeaderCanRunExperimentWithVerifiedModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let training = root.appendingPathComponent("training")
        let held = root.appendingPathComponent("held")
        defer { try? FileManager.default.removeItem(at: root) }
        for fixture in [training, held] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Tests"), withIntermediateDirectories: true)
            try "independent".write(to: fixture.appendingPathComponent("Tests/Check.swift"), atomically: true, encoding: .utf8)
            try "bad".write(to: fixture.appendingPathComponent("answer.txt"), atomically: true, encoding: .utf8)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessModelProtocol.self]
        HarnessModelProtocol.includeRouteHeader = false
        HarnessModelProtocol.requestNumber = 0
        HarnessModelProtocol.requestBodies = []
        HarnessModelProtocol.authorizationHeaders = []
        defer { HarnessModelProtocol.includeRouteHeader = true }
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://direct.example.test/chat")!,
                                           model: "fixed", session: URLSession(configuration: configuration))
            .identifyingDirectEndpoint()
        let identity = try await client.complete(messages: [], tools: [])
        let endpointRoute = try XCTUnwrap(identity.routedVia)
        XCTAssertTrue(endpointRoute.hasPrefix("endpoint-sha256:"))
        HarnessModelProtocol.requestNumber = 0
        HarnessModelProtocol.requestBodies = []
        HarnessModelProtocol.authorizationHeaders = []
        let executor = LiveHarnessExecutor(client: client.selectingModel("fixed"), verificationCommands: [
            "training": "test \"$(cat answer.txt)\" = good",
            "held": "test \"$(cat answer.txt)\" = good"
        ], approve: { _ in true })
        let coordinator = HarnessCoordinator(profileURL: root.appendingPathComponent("profile.json"), executor: executor)
        await coordinator.setEnabled(true)
        let report = try await coordinator.experiment(
            baseline: HarnessProfile(instructions: "baseline"),
            training: [HarnessTask(name: "training", prompt: "fix", fixture: training)],
            heldOut: [HarnessTask(name: "held", prompt: "fix", fixture: held)],
            route: HarnessRoute(provider: endpointRoute, model: "fixed"), maxModelCalls: 6
        )
        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.modelCalls, 5)
        let profile = try await coordinator.activeProfile(standard: HarnessProfile(instructions: "baseline"))
        XCTAssertEqual(profile.instructions, "candidate")
    }

    func testRetryBeforeResponseCountsBothAttemptsAndValidatesSuccessfulRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessRetryProtocol.self]
        HarnessRetryProtocol.count = 0
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!,
                                            model: "fixed", session: URLSession(configuration: configuration))
        let executor = LiveHarnessExecutor(client: client, verificationCommands: [:], approve: { _ in false })
        let run = try await executor.run(task: HarnessTask(name: "test", prompt: "inspect", fixture: root),
                                         workspace: root, profile: HarnessProfile(instructions: "inspect"),
                                         route: HarnessRoute(provider: "fixed-provider", model: "fixed"), maxModelCalls: 2)
        XCTAssertEqual(run.modelCalls, 2)
        XCTAssertEqual(run.route, HarnessRoute(provider: "fixed-provider", model: "fixed"))
        XCTAssertEqual(HarnessRetryProtocol.count, 2)
    }

    func testRetryStillRejectsChangedRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessRetryProtocol.self]
        HarnessRetryProtocol.count = 0
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!,
                                            model: "fixed", session: URLSession(configuration: configuration))
        let executor = LiveHarnessExecutor(client: client, verificationCommands: [:], approve: { _ in false })
        do {
            _ = try await executor.run(task: HarnessTask(name: "test", prompt: "inspect", fixture: root),
                                       workspace: root, profile: HarnessProfile(instructions: "inspect"),
                                       route: HarnessRoute(provider: "other-provider", model: "fixed"), maxModelCalls: 2)
            XCTFail("A retry must not weaken route validation")
        } catch LiveHarnessError.unverifiedModel {}
    }

    func testCancelledVerifierStopsItsChildProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = root.appendingPathComponent("fixture")
        let workspace = root.appendingPathComponent("workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try "trusted".write(to: fixture.appendingPathComponent("Tests/Sample.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: fixture, to: workspace)
        let client = OpenAICompatibleClient(endpoint: URL(string: "http://localhost:1")!, model: "unused")
        let command = "(sleep 1; touch escaped) & touch ready; wait"
        let executor = LiveHarnessExecutor(client: client, verificationCommands: ["held": command], approve: { _ in true })
        let run = Task { try await executor.verify(task: HarnessTask(name: "held", prompt: "", fixture: fixture), workspace: workspace) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ready").path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ready").path))
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("escaped").path))
    }

    func testRealCoordinatorRunsAgentAndAcceptsVerifiedCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let training = root.appendingPathComponent("training")
        let held = root.appendingPathComponent("held")
        defer { try? FileManager.default.removeItem(at: root) }
        for fixture in [training, held] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Tests"), withIntermediateDirectories: true)
            try "independent".write(to: fixture.appendingPathComponent("Tests/Check.swift"), atomically: true, encoding: .utf8)
            try "bad".write(to: fixture.appendingPathComponent("answer.txt"), atomically: true, encoding: .utf8)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessModelProtocol.self]
        HarnessModelProtocol.requestNumber = 0
        HarnessModelProtocol.requestBodies = []
        HarnessModelProtocol.authorizationHeaders = []
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!, model: "auto:fast", apiKey: "test-key", session: URLSession(configuration: configuration))
        let executor = LiveHarnessExecutor(client: client.selectingModel("fixed"), verificationCommands: [
            "training": "test \"$(cat answer.txt)\" = good",
            "held": "test \"$(cat answer.txt)\" = good"
        ], approve: { _ in true })
        let coordinator = HarnessCoordinator(profileURL: root.appendingPathComponent("profile.json"), executor: executor)
        await coordinator.setEnabled(true)
        let report = try await coordinator.experiment(
            baseline: HarnessProfile(instructions: "baseline"),
            training: [HarnessTask(name: "training", prompt: "fix", fixture: training)],
            heldOut: [HarnessTask(name: "held", prompt: "fix", fixture: held)],
            route: HarnessRoute(provider: "fixed-provider", model: "fixed"),
            maxModelCalls: 6
        )
        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.modelCalls, 5)
        XCTAssertEqual(HarnessModelProtocol.requestBodies.count, 5)
        for body in HarnessModelProtocol.requestBodies {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "fixed")
        }
        XCTAssertEqual(HarnessModelProtocol.authorizationHeaders, Array(repeating: "Bearer test-key", count: 5))
        let proposal = try XCTUnwrap(JSONSerialization.jsonObject(with: HarnessModelProtocol.requestBodies[1]) as? [String: Any])
        let messages = try XCTUnwrap(proposal["messages"] as? [[String: Any]])
        let evidence = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(evidence.contains("Независимая проверка: не пройдена"))
        XCTAssertEqual(try String(contentsOf: held.appendingPathComponent("answer.txt"), encoding: .utf8), "bad")
        let profile = try await coordinator.activeProfile(standard: HarnessProfile(instructions: "baseline"))
        XCTAssertEqual(profile.instructions, "candidate")
    }

    func testModifiedHeldOutTestsAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = root.appendingPathComponent("fixture")
        let workspace = root.appendingPathComponent("workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try "trusted".write(to: fixture.appendingPathComponent("Tests/SampleTests.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: fixture, to: workspace)
        try "tampered".write(to: workspace.appendingPathComponent("Tests/SampleTests.swift"), atomically: true, encoding: .utf8)
        let client = OpenAICompatibleClient(endpoint: URL(string: "http://localhost:1")!, model: "unused")
        let executor = LiveHarnessExecutor(client: client, verificationCommands: ["held": "true"], approve: { _ in true })
        do {
            _ = try await executor.verify(task: HarnessTask(name: "held", prompt: "", fixture: fixture), workspace: workspace)
            XCTFail("A modified verifier must not accept a candidate")
        } catch LiveHarnessError.untrustedTests {}
    }

    func testVerifierMustHaveTestFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = root.appendingPathComponent("fixture")
        let workspace = root.appendingPathComponent("workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: workspace)
        let client = OpenAICompatibleClient(endpoint: URL(string: "http://localhost:1")!, model: "unused")
        let executor = LiveHarnessExecutor(client: client, verificationCommands: ["held": "true"], approve: { _ in true })
        do {
            _ = try await executor.verify(task: HarnessTask(name: "held", prompt: "", fixture: fixture), workspace: workspace)
            XCTFail("A candidate needs independent test files")
        } catch LiveHarnessError.untrustedTests {}
    }

    func testVerifierRejectsChangedSourceSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = root.appendingPathComponent("fixture")
        let workspace = root.appendingPathComponent("workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        let sourceTest = fixture.appendingPathComponent("Tests/SampleTests.swift")
        try "trusted".write(to: sourceTest, atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: fixture, to: workspace)
        let client = OpenAICompatibleClient(endpoint: URL(string: "http://localhost:1")!, model: "unused")
        let command = "printf tampered > '\(sourceTest.path)'"
        let executor = LiveHarnessExecutor(client: client, verificationCommands: ["held": command], approve: { _ in true })
        do {
            _ = try await executor.verify(task: HarnessTask(name: "held", prompt: "", fixture: fixture), workspace: workspace)
            XCTFail("A changed source snapshot must not be accepted")
        } catch LiveHarnessError.untrustedTests {}
    }
}

private final class HarnessRetryProtocol: URLProtocol {
    static var count = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        if Self.count == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream", "X-Routed-Via": "fixed-provider"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let stream = #"data: {"model":"fixed","choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HarnessModelProtocol: URLProtocol {
    static var requestNumber = 0
    static var requestBodies: [Data] = []
    static var authorizationHeaders: [String] = []
    static var includeRouteHeader = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestNumber += 1
        Self.authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        if let body = request.httpBody {
            Self.requestBodies.append(body)
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
            Self.requestBodies.append(data)
        }
        var headers = ["Content-Type": "text/event-stream"]
        if Self.includeRouteHeader { headers["X-Routed-Via"] = "fixed-provider" }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body: String
        switch Self.requestNumber {
        case 2:
            body = #"data: {"model":"fixed","choices":[{"index":0,"delta":{"content":"candidate"},"finish_reason":"stop"}]}"#
        case 4:
            body = #"data: {"model":"fixed","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"replace_text","arguments":"{\"path\":\"answer.txt\",\"old\":\"bad\",\"new\":\"good\"}"}}]},"finish_reason":"tool_calls"}]}"#
        default:
            body = #"data: {"model":"fixed","choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"#
        }
        client?.urlProtocol(self, didLoad: Data((body + "\n\ndata: [DONE]\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

