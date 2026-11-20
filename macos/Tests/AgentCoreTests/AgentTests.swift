import Foundation
import XCTest
@testable import AgentCore

final class AgentTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try "old\n".write(to: url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        return url
    }

    func testRefusedEditLeavesFileUnchanged() throws {
        let url = try workspace()
        let agent = Agent(
            workspace: url,
            provider: OneEditProvider(),
            onEvent: { _ in },
            approve: { _ in false }
        )

        XCTAssertFalse(try agent.run(task: "").success)
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("file.txt"), encoding: .utf8), "old\n")
    }

    func testEditDoesNotOverwriteChangeMadeDuringApproval() throws {
        let url = try workspace()
        let file = url.appendingPathComponent("file.txt")
        let agent = Agent(
            workspace: url,
            provider: OneEditProvider(),
            onEvent: { _ in },
            approve: { _ in
                try! "user's change\n".write(to: file, atomically: true, encoding: .utf8)
                return true
            }
        )

        XCTAssertFalse(try agent.run(task: "").success)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user's change\n")
    }

    func testDuplicateToolCallIDIsRejected() throws {
        let url = try workspace()
        let agent = Agent(workspace: url, provider: RepeatedCallProvider(), onEvent: { _ in }, approve: { _ in true })
        XCTAssertThrowsError(try agent.run(task: ""))
    }

    func testFixtureProviderStopsOnCompilerFailure() throws {
        let result = ToolResult(
            id: "test-before",
            output: "error: compiler failed before any tests ran",
            succeeded: false,
            exitCode: 1
        )
        let response = try TestProvider().next(task: "", results: [result])
        guard case .complete(_, let success) = response else {
            return XCTFail("A compiler error must not trigger an edit.")
        }
        XCTAssertFalse(success)
    }
}

private struct OneEditProvider: AgentProvider {
    func next(task: String, results: [ToolResult]) throws -> ProviderResponse {
        if results.isEmpty {
            return .toolCall(ToolCall(id: "edit", action: .replace(path: "file.txt", old: "old", new: "new")))
        }
        return .complete(message: "done", success: results[0].succeeded)
    }
}

private struct RepeatedCallProvider: AgentProvider {
    func next(task: String, results: [ToolResult]) throws -> ProviderResponse {
        return .toolCall(ToolCall(id: "same", action: .read(path: "file.txt")))
    }
}
