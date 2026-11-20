import Foundation
import XCTest
@testable import AgentCore

final class WorkspaceGitTests: XCTestCase {
    func testDiffAndHistoryAreRestrictedToSelectedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "before\n".write(to: project.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "outside before\n".write(to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        let setup = try await CommandRunner.runResult("/usr/bin/git init -q && /usr/bin/git add . && /usr/bin/git -c user.name=Test -c user.email=test@example.invalid commit -qm initial", cwd: root)
        XCTAssertEqual(setup.exitCode, 0, setup.output)
        try "staged\n".write(to: project.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let add = try await CommandRunner.runResult("/usr/bin/git add project/file.txt", cwd: root)
        XCTAssertEqual(add.exitCode, 0, add.output)
        try "unstaged\n".write(to: project.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: project.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "outside changed\n".write(to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)

        let diff = try await WorkspaceGit.diff(workspace: project)
        XCTAssertTrue(diff.contains("+staged"), diff)
        XCTAssertTrue(diff.contains("+unstaged"), diff)
        XCTAssertTrue(diff.contains("new.txt"), diff)
        XCTAssertFalse(diff.contains("outside"), diff)
        let history = try await WorkspaceGit.history(workspace: project)
        XCTAssertTrue(history.contains("initial"), history)
    }

    func testNonRepositoryReturnsMeaningfulFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await WorkspaceGit.diff(workspace: directory)
        XCTAssertTrue(result.contains("Не удалось прочитать Git"), result)
    }
}
