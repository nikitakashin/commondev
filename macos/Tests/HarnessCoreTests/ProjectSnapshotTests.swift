import Foundation
import XCTest
@testable import HarnessCore

final class ProjectSnapshotTests: XCTestCase {
    func testSnapshotPreservesProjectAndSkipsCaches() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = parent.appendingPathComponent("source")
        let destination = parent.appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try "hello".write(to: source.appendingPathComponent("Sources/file.swift"), atomically: true, encoding: .utf8)
        try "secret".write(to: source.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: parent) }

        try HarnessProjectSnapshot.copy(from: source, to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Sources/file.swift"), encoding: .utf8), "hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".build").path))
    }

    func testSnapshotRejectsExternalSymlinkAndRemovesPartialCopy() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = parent.appendingPathComponent("source")
        let destination = parent.appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("outside").path,
                                                   withDestinationPath: "/tmp")
        defer { try? FileManager.default.removeItem(at: parent) }

        XCTAssertThrowsError(try HarnessProjectSnapshot.copy(from: source, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
