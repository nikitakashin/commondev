import Foundation
import XCTest
@testable import AgentCore

final class WorkspaceSearchTests: XCTestCase {
    func testSearchFindsFilesAndSkipsSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "hello world\n".write(to: directory.appendingPathComponent("one.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("external"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        let root = directory.resolvingSymlinksInPath()
        XCTAssertEqual(try WorkspaceSearch.find(pattern: "*.swift", workspace: root), "one.swift")
        XCTAssertEqual(try WorkspaceSearch.search(query: "world", workspace: root), "one.swift:1: hello world")
        XCTAssertEqual(try WorkspaceSearch.find(pattern: "passwd", workspace: root), "Совпадений нет.")
    }

    func testSearchFindsTextInLargeUTF8FileAcrossReadBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Cross the old 1 MB file limit and several 16 KB read boundaries.
        let text = String(repeating: "обычная строка\n", count: 60_000) + "найдено в конце\n"
        XCTAssertGreaterThan(text.utf8.count, 1_000_000)
        try text.write(to: directory.appendingPathComponent("large.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try WorkspaceSearch.search(query: "найдено", workspace: directory.resolvingSymlinksInPath()),
                       "large.swift:60001: найдено в конце")
    }

    func testSearchReportsSkippedLongLineAndContinuesWithNextLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = String(repeating: "x", count: 1_000_001) + "\nneedle\n"
        try text.write(to: directory.appendingPathComponent("long.txt"), atomically: true, encoding: .utf8)
        let result = try WorkspaceSearch.search(query: "needle", workspace: directory.resolvingSymlinksInPath())
        XCTAssertTrue(result.contains("long.txt:2: needle"))
        XCTAssertTrue(result.contains("Строки длиннее 1 МБ пропущены"))
        let notFound = try WorkspaceSearch.search(query: "absent", workspace: directory.resolvingSymlinksInPath())
        XCTAssertTrue(notFound.contains("Совпадений в просмотренных строках нет"))
        XCTAssertTrue(notFound.contains("Строки длиннее 1 МБ пропущены"))
    }
}
