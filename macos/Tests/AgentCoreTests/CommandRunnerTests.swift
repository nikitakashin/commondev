import Foundation
import XCTest
@testable import AgentCore

final class CommandRunnerTests: XCTestCase {
    func testCancellationTerminatesDescendants() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let command = Task {
            try await CommandRunner.run("(sleep 1; touch child-finished) & wait", cwd: workspace)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        command.cancel()
        do {
            _ = try await command.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("child-finished").path))
    }

    func testCommandOutputAndExitStatus() async throws {
        let workspace = FileManager.default.temporaryDirectory
        let output = try await CommandRunner.run("printf output; exit 7", cwd: workspace)
        XCTAssertTrue(output.contains("output"))
        XCTAssertTrue(output.contains("Код завершения: 7"))
    }

    func testLargeOutputIsDrainedAndLimited() async throws {
        let result = try await CommandRunner.runResult("/usr/bin/yes abc | /usr/bin/head -c 2000000", cwd: FileManager.default.temporaryDirectory)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.hasPrefix("abc\nabc\n"))
        XCTAssertTrue(result.output.hasSuffix("\nВывод ограничен."))
        XCTAssertLessThan(result.output.utf8.count, 201_000)
    }

    func testCancellationWithContinuousOutput() async throws {
        let command = Task { try await CommandRunner.runResult("/usr/bin/yes output", cwd: FileManager.default.temporaryDirectory) }
        try await Task.sleep(nanoseconds: 200_000_000)
        command.cancel()
        do {
            _ = try await command.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }
}
