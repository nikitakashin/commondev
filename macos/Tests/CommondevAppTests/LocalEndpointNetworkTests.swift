import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import CommondevApp

/// Exercises the real URLSession/HTTP/SSE path using only a loopback server.
@MainActor
final class LocalEndpointNetworkTests: XCTestCase {
    func testKeyboardTurnInHostedChatWithApprovalAndGeneratedTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storageRoot: root.appendingPathComponent("store"))
        let server = try LoopbackModelServer(provideTitle: true)
        defer { server.stop() }
        app.newChat(inProject: root.path)
        try "old".write(to: root.appendingPathComponent("example.txt"), atomically: true, encoding: .utf8)
        app.useFreeModel = false
        app.endpoint = "http://127.0.0.1:\(server.port)/v1/chat/completions"
        app.modelName = "local-test"

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ContentView(model: app))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 where !(window.firstResponder is ComposerTextView) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let editor = try XCTUnwrap(window.firstResponder as? ComposerTextView)
        func enter(_ modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            window.sendEvent(event)
        }

        editor.insertText("Проверь файл", replacementRange: editor.selectedRange())
        try enter(.shift)
        editor.insertText("и замени old", replacementRange: editor.selectedRange())
        let prompt = "Проверь файл\nи замени old"
        XCTAssertEqual(app.draft, prompt)
        XCTAssertFalse(app.isRunning)
        try enter()
        XCTAssertTrue(app.draft.isEmpty)
        let sent = try XCTUnwrap(app.selectedSession?.messages.first)
        XCTAssertEqual(sent.text, prompt)
        XCTAssertEqual(app.activeUserMessageID, sent.id)
        XCTAssertEqual(app.selectedSession?.displayName, "Проверь файл и замени old")
        try enter()
        for _ in 0..<200 where app.isRunning && app.approval == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(app.approval)
        XCTAssertFalse(app.hasQueuedMessages)
        app.resolveApproval(true)
        for _ in 0..<200 where app.selectedSession?.name != "Замена текста в example.txt" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(app.activeUserMessageID)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("example.txt"), encoding: .utf8), "new")
        let saved = try XCTUnwrap(try SessionStore(root: root.appendingPathComponent("store")).load().first)
        XCTAssertEqual(saved.name, "Замена текста в example.txt")
        XCTAssertEqual(saved.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(saved.messages.last(where: { $0.role == "assistant" })?.text, "done")
        XCTAssertEqual(server.requests.count, 3)
        let titleBody = try XCTUnwrap(server.requests.last?.body)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: titleBody) as? [String: Any])
        XCTAssertNil(payload["tools"])
        let titleMessages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertEqual(titleMessages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(titleMessages.last?["content"], prompt)
    }

    func testRealLocalEndpointApprovalAndRejection() async throws {
        for allowed in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("project", isDirectory: true)
            let storage = root.appendingPathComponent("storage", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let file = project.appendingPathComponent("example.txt")
            try "old".write(to: file, atomically: true, encoding: .utf8)

            let server = try LoopbackModelServer()
            defer { server.stop() }
            let app = AppModel(storageRoot: storage)
            let chat = ChatSession(name: "network fixture", projectPath: project.path)
            app.sessions = [chat]
            app.selectSession(chat.id)
            app.useFreeModel = false
            app.endpoint = "http://127.0.0.1:\(server.port)/v1/chat/completions"
            app.modelName = "local-test"
            app.apiKey = "fixture-token"
            app.draft = "Change the fixture"
            app.send()

            for _ in 0..<300 {
                if app.approval != nil || !app.isRunning { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let approval = try XCTUnwrap(app.approval, "The streamed tool call must reach the approval sheet")
            XCTAssertTrue(approval.detail.contains("example.txt"))
            XCTAssertTrue(approval.detail.contains("-old"))
            XCTAssertTrue(approval.detail.contains("+new"))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
            app.resolveApproval(allowed)
            for _ in 0..<300 {
                if !app.isRunning { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertFalse(app.isRunning)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), allowed ? "new" : "old")
            XCTAssertTrue(app.selectedSession?.messages.contains { $0.role == "assistant" && $0.text == "done" } == true)
            XCTAssertEqual(server.finished.wait(timeout: .now() + 3), .success)
            let captured = server.requests
            XCTAssertEqual(captured.count, 2)
            guard captured.count == 2 else { continue }
            XCTAssertTrue(captured[0].headers.lowercased().contains("authorization: bearer fixture-token"))
            let first = try XCTUnwrap(try JSONSerialization.jsonObject(with: captured[0].body) as? [String: Any])
            XCTAssertEqual(first["model"] as? String, "local-test")
            XCTAssertEqual(first["stream"] as? Bool, true)
            let second = try XCTUnwrap(try JSONSerialization.jsonObject(with: captured[1].body) as? [String: Any])
            let messages = try XCTUnwrap(second["messages"] as? [[String: Any]])
            let result = try XCTUnwrap(messages.last { $0["role"] as? String == "tool" })
            XCTAssertEqual(result["tool_call_id"] as? String, "edit-1")
            XCTAssertTrue((result["content"] as? String ?? "").contains(allowed ? "Файл изменён" : "отклонена"))
            let restored = AppModel(storageRoot: storage)
            XCTAssertTrue(restored.selectedSession?.conversation?.contains { $0["tool_call_id"] == .string("edit-1") } == true)
        }
    }
}

private struct CapturedRequest {
    let headers: String
    let body: Data
}

/// Minimal HTTP/1.1 server; binds exclusively to 127.0.0.1 on an ephemeral port.
private final class LoopbackModelServer: @unchecked Sendable {
    let port: UInt16
    let finished = DispatchGroup()
    private let listener: Int32
    private let lock = NSLock()
    private var captured: [CapturedRequest] = []
    var requests: [CapturedRequest] { lock.lock(); defer { lock.unlock() }; return captured }

    init(provideTitle: Bool = false) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0, listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard nameResult == 0 else { close(fd); throw POSIXError(.EIO) }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
        finished.enter()
        DispatchQueue.global().async { [self] in
            defer { finished.leave() }
            let responses = [Self.toolStream, Self.answerStream] + (provideTitle ? [Self.titleStream] : [])
            for content in responses {
                var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, 10_000) > 0 else { return }
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                defer { close(connection) }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var noSigPipe: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                guard let request = Self.readRequest(connection) else { return }
                lock.lock(); captured.append(request); lock.unlock()
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(content.utf8.count)\r\nConnection: close\r\n\r\n"
                let bytes = Array((header + content).utf8)
                // Deliberately split bytes across writes to exercise stream framing.
                for chunk in stride(from: 0, to: bytes.count, by: 17) {
                    let end = min(chunk + 17, bytes.count)
                    let sent = bytes[chunk..<end].withUnsafeBytes { raw -> Bool in
                        guard let base = raw.baseAddress else { return false }
                        var offset = 0
                        while offset < raw.count {
                            let count = send(connection, base.advanced(by: offset), raw.count - offset, 0)
                            if count <= 0 { return false }
                            offset += count
                        }
                        return true
                    }
                    if !sent { return }
                }
                shutdown(connection, SHUT_RDWR)
            }
        }
    }

    func stop() { shutdown(listener, SHUT_RDWR); close(listener) }

    private static func readRequest(_ fd: Int32) -> CapturedRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var split: Range<Data.Index>?
        while data.count < 2_000_000 {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            split = data.range(of: Data("\r\n\r\n".utf8))
            guard let split else { continue }
            let headers = String(decoding: data[..<split.lowerBound], as: UTF8.self)
            let length = headers.components(separatedBy: "\r\n").compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first ?? -1
            guard length >= 0 else { return nil }
            if data.count - split.upperBound >= length {
                return CapturedRequest(headers: headers, body: data.subdata(in: split.upperBound..<(split.upperBound + length)))
            }
        }
        return nil
    }

    private static let toolStream = #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"edit-1","type":"function","function":{"name":"replace_text","arguments":"{\"path\":\"example.txt\","}}]}}]}"# + "\n\n" + #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"old\":\"old\",\"new\":\"new\"}"}}]},"finish_reason":"tool_calls"}]}"# + "\n\ndata: [DONE]\n\n"
    private static let answerStream = #"data: {"choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
    private static let titleStream = #"data: {"choices":[{"index":0,"delta":{"content":"Замена текста в example.txt"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
}
