import Foundation
import XCTest
import AgentCore
@testable import CommondevApp

final class StorageTests: XCTestCase {
    @MainActor
    func testNewChatReusesEmptySessionInTargetProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storageRoot: root)
        let firstProject = root.appendingPathComponent("first").path
        let secondProject = root.appendingPathComponent("second").path

        app.newChat(inProject: firstProject)
        let firstID = try XCTUnwrap(app.selectedID)
        for _ in 0..<10 { app.newChat() }
        XCTAssertEqual(app.selectedID, firstID)
        XCTAssertEqual(app.sessions.count, 1)

        app.newChat(inProject: secondProject)
        app.newChat(inProject: firstProject)
        XCTAssertEqual(app.selectedID, firstID)
        XCTAssertEqual(app.sessions.count, 2)
    }

    @MainActor
    func testRenameAndDeletePersistAndSelectRemainingChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storageRoot: root)
        app.newChat()
        let removed = try XCTUnwrap(app.selectedID)
        app.renameChat(removed, to: "  Новое название  ")
        XCTAssertEqual(try SessionStore(root: root).load().first?.name, "Новое название")
        app.draft = "Черновик"
        app.newChat()
        let remaining = try XCTUnwrap(app.selectedID)

        app.selectSession(removed)
        app.deleteChat(removed)
        XCTAssertEqual(app.selectedID, remaining)
        XCTAssertTrue(app.draft.isEmpty)
        XCTAssertEqual(try SessionStore(root: root).load().map(\.id), [remaining])
        let removedFile = root.appendingPathComponent("Sessions/\(removed.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedFile.path))
    }

    @MainActor
    func testNewChatsKeepTheirDraftAndOptionalProjectIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storageRoot: root)
        app.newChat()
        let first = try XCTUnwrap(app.selectedID)
        XCTAssertNil(app.selectedSession?.project)
        XCTAssertEqual(app.selectedWorkMode, .high)
        app.draft = "Оставить в первом чате"
        app.setProjectFolder(root)

        app.newChat()
        let second = try XCTUnwrap(app.selectedID)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(app.selectedSession?.project?.path, root.resolvingSymlinksInPath().path)
        XCTAssertTrue(app.draft.isEmpty)
        app.setProjectFolder(root)
        app.setWorkMode(.ultracode)
        app.selectSession(first)
        XCTAssertEqual(app.draft, "Оставить в первом чате")
        XCTAssertEqual(app.selectedWorkMode, .high)
        app.setProjectFolder(nil)

        let restored = AppModel(storageRoot: root)
        XCTAssertEqual(restored.sessions.count, 2)
        restored.selectSession(second)
        XCTAssertEqual(restored.selectedSession?.project?.path, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(restored.selectedWorkMode, .ultracode)
        restored.selectSession(first)
        XCTAssertNil(restored.selectedSession?.project)
        XCTAssertEqual(ChatSession(name: "legacy", effortRaw: "auto").workMode, .high)
    }

    @MainActor
    func testProjectChoiceAndPinsSurviveRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProject = root.appendingPathComponent("first")
        let secondProject = root.appendingPathComponent("second")
        let app = AppModel(storageRoot: root)
        app.newChat(inProject: firstProject.path)
        let pinned = try XCTUnwrap(app.selectedID)
        app.togglePin(pinned)
        app.newChat(inProject: secondProject.path)
        app.selectSession(pinned)

        let reopened = AppModel(storageRoot: root)
        XCTAssertEqual(reopened.sessions.first(where: { $0.id == pinned })?.pinned, true)
        reopened.newChat()
        XCTAssertEqual(reopened.selectedSession?.projectPath, firstProject.path)
        XCTAssertNil(reopened.selectedSession?.pinned)
        reopened.togglePin(pinned)
        XCTAssertNil(try SessionStore(root: root).load().first(where: { $0.id == pinned })?.pinned)
    }

    func testWorktreeUsesSelectedBranchAndKeepsOriginalWorkingCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("repo", isDirectory: true)
        let subdirectory = project.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func git(_ arguments: String...) async throws -> String {
            let result = try await CommandRunner.runResult(executable: "/usr/bin/git", arguments: arguments, cwd: project)
            XCTAssertEqual(result.exitCode, 0, result.output)
            return result.output.trimmingCharacters(in: .newlines)
        }

        _ = try await git("init", "-b", "main")
        let file = subdirectory.appendingPathComponent("file.txt")
        try "base".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git("add", ".")
        _ = try await git("-c", "user.name=Commondev Test", "-c", "user.email=test@example.test", "commit", "-m", "base")
        _ = try await git("branch", "chat-base")
        try "main".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git("-c", "user.name=Commondev Test", "-c", "user.email=test@example.test", "commit", "-am", "main")
        try "uncommitted change".write(to: file, atomically: true, encoding: .utf8)

        let checkout = root.appendingPathComponent("isolated checkout", isDirectory: true)
        let scoped = try await ChatGit.createWorktree(for: subdirectory, branch: "chat-base", at: checkout)
        XCTAssertEqual(scoped.path, checkout.appendingPathComponent("nested").path)
        XCTAssertEqual(try String(contentsOf: scoped.appendingPathComponent("file.txt"), encoding: .utf8), "base")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "uncommitted change")
        let originalBranch = try await git("branch", "--show-current")
        XCTAssertEqual(originalBranch, "main")
    }

    @MainActor
    func testStreamingWritesAreGroupedAndCheckpointsFlushImmediately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storageRoot: root)
        let chat = ChatSession(name: "test", projectPath: root.path)
        app.sessions = [chat]
        app.selectSession(chat.id)
        app.setWorkMode(.medium)
        let store = SessionStore(root: root)
        for _ in 0..<64 { app.handle(.text("a"), sessionID: chat.id) }
        XCTAssertTrue(try store.load()[0].messages.isEmpty)
        let partial = String(repeating: "a", count: 64)
        for _ in 0..<100 {
            if try store.load()[0].messages.last?.text == partial { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(try store.load()[0].messages.last?.text, partial)
        app.handle(.text("b"), sessionID: chat.id)
        app.handle(.conversation([["role": .string("user"), "content": .string("task")]]), sessionID: chat.id)
        let saved = try store.load()[0]
        XCTAssertEqual(saved.messages.last?.text, partial + "b")
        XCTAssertEqual(saved.conversation?.last?["content"], .string("task"))
    }

    func testLockExcludesAnotherProcessAndReleasesOnClose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var owner = try InstanceLock(directory: root)
        XCTAssertNotNil(owner)
        XCTAssertNil(try InstanceLock(directory: root))
        func probe() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
                import fcntl, sys
                with open(sys.argv[1], 'r+') as lock:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        sys.exit(42)
                """, root.appendingPathComponent("app.lock").path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try probe(), 42)
        owner = nil
        XCTAssertEqual(try probe(), 0)
    }

    func testLegacyMigrationCommitsIndexLastAndWritesOnlyChangedSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let first = ChatSession(name: "first", projectPath: root.path, messages: [ChatMessage(role: "user", text: "queued", queued: true)])
        let second = ChatSession(name: "second", projectPath: root.path)
        let original = try JSONEncoder().encode([first, second])
        try original.write(to: store.indexURL)
        var sessions = try store.load()
        let directory = root.appendingPathComponent("Sessions")
        let otherFile = directory.appendingPathComponent(second.id.uuidString + ".json")
        try FileManager.default.createDirectory(at: otherFile, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.save(sessions, changed: first.id))
        XCTAssertEqual(try Data(contentsOf: store.indexURL), original)
        try FileManager.default.removeItem(at: otherFile)
        try store.save(sessions, changed: first.id)
        let marker = Date(timeIntervalSince1970: 1_000)
        for url in [otherFile, store.indexURL] {
            try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: url.path)
        }
        sessions[0].name = "renamed"
        try store.save(sessions, changed: first.id)
        let after = try SessionStore(root: root).load()
        XCTAssertEqual(after.map(\.name), ["renamed", "second"])
        XCTAssertEqual(after.first?.messages.first?.queued, true)
        for url in [otherFile, store.indexURL] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, marker)
        }
    }
}
