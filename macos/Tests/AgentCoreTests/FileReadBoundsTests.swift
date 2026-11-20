import Darwin
import Foundation
import XCTest
@testable import AgentCore

final class FileReadBoundsTests: XCTestCase {
    func testLargeFilesCanBeReadInChunksButNotRewrittenAsAWhole() async throws {
        for operation in ["read_file", "replace_text"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("file.txt")
            try Data(repeating: 65, count: 1_000_001).write(to: file)
            let capture = BoundsCapture()
            let agent = makeAgent(root: root, operation: operation, capture: capture)
            _ = try await agent.run(task: "Inspect the file")
            let result = await capture.result
            let approvals = await capture.approvals
            if operation == "read_file" {
                XCTAssertTrue(result.contains("offset_bytes=64000"))
                XCTAssertTrue(result.hasPrefix(String(repeating: "A", count: 64_000)))
            } else {
                XCTAssertTrue(result.contains("превышает лимит"))
            }
            XCTAssertEqual(approvals, 0)
            XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, 1_000_001)
        }
    }

    func testChunkOffsetsDoNotSplitUTF8Characters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "яяяя".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let first = BoundsCapture()
        _ = try await makeAgent(root: root, operation: "read_file", capture: first, offset: 0, maxBytes: 5).run(task: "Read")
        let firstResult = await first.result
        XCTAssertTrue(firstResult.hasPrefix("яя\n"))
        XCTAssertTrue(firstResult.contains("offset_bytes=4"))
        let second = BoundsCapture()
        _ = try await makeAgent(root: root, operation: "read_file", capture: second, offset: 4, maxBytes: 5).run(task: "Read")
        let secondResult = await second.result
        XCTAssertTrue(secondResult.hasPrefix("яя\n"))
        XCTAssertTrue(secondResult.contains("Конец файла"))
    }

    func testReadingFIFOEndsWithoutWaitingForWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(mkfifo(root.appendingPathComponent("file.txt").path, 0o600), 0)
        let capture = BoundsCapture()
        let agent = makeAgent(root: root, operation: "read_file", capture: capture)
        _ = try await agent.run(task: "Inspect the file")
        let result = await capture.result
        XCTAssertTrue(result.contains("только обычные файлы"))
    }

    func testChunkReadRejectsPathsAndLinksOutsideProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("secret.txt")
        try "outside workspace".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link.txt"), withDestinationURL: secret)
        for path in ["../secret.txt", "link.txt"] {
            let capture = BoundsCapture()
            _ = try await makeAgent(root: project, operation: "read_file", capture: capture, offset: 0, maxBytes: 10, path: path).run(task: "Read")
            let result = await capture.result
            XCTAssertTrue(result.contains("Путь за пределами проекта"))
            XCTAssertFalse(result.contains("outside workspace"))
        }
    }

    private func makeAgent(root: URL, operation: String, capture: BoundsCapture, offset: Int? = nil, maxBytes: Int? = nil, path: String = "file.txt") -> LiveAgent {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundsProtocol.self]
        BoundsProtocol.configure(operation, offset: offset, maxBytes: maxBytes, path: path)
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://example.test/chat")!,
                                             model: "fixture", session: URLSession(configuration: configuration))
        return LiveAgent(workspace: root, client: client, onEvent: { event in
            if case let .toolFinished(_, result) = event { await capture.setResult(result) }
        }, approve: { _ in await capture.countApproval(); return true })
    }
}

private actor BoundsCapture {
    private(set) var result = ""
    private(set) var approvals = 0
    func setResult(_ value: String) { result = value }
    func countApproval() { approvals += 1 }
}

private final class BoundsProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0
    private static var operation = "read_file"
    private static var offset: Int?
    private static var maxBytes: Int?
    private static var path = "file.txt"
    static func configure(_ value: String, offset: Int?, maxBytes: Int?, path: String) {
        lock.lock(); defer { lock.unlock() }
        requests = 0; operation = value
        self.offset = offset; self.maxBytes = maxBytes
        self.path = path
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let first = Self.requests == 1
        let operation = Self.operation
        let offset = Self.offset, maxBytes = Self.maxBytes, path = Self.path
        Self.lock.unlock()
        let data: String
        if first {
            var args: [String: Any] = operation == "read_file"
                ? ["path": path] : ["path": path, "old": "A", "new": "B"]
            if let offset { args["offset_bytes"] = offset }
            if let maxBytes { args["max_bytes"] = maxBytes }
            let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            let event: [String: Any] = ["choices": [["index": 0, "delta": ["tool_calls": [[
                "index": 0, "id": "bounds-1", "type": "function",
                "function": ["name": operation, "arguments": arguments]
            ]]], "finish_reason": "tool_calls"]]]
            data = String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        } else {
            data = #"{"choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(("data: " + data + "\n\ndata: [DONE]\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
