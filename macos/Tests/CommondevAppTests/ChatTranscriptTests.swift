import SwiftUI
import XCTest
@testable import CommondevApp

final class ChatTranscriptTests: XCTestCase {
    func testOlderConsumedQueueIsDisplayedAtItsOwnRun() {
        let first = ChatMessage(role: "user", text: "first")
        let effort = ChatMessage(role: "system", text: "Effort: High")
        let queued = ChatMessage(role: "user", text: "second", queued: false)
        let result = ChatMessage(role: "tool", text: "[1] completed")
        let answer = ChatMessage(role: "assistant", text: "answer to first")
        let nextEffort = ChatMessage(role: "system", text: "Effort: Low")
        let historical = [first, effort, queued, result, answer, nextEffort]
        let current = [first, effort, result, answer, queued, nextEffort]
        for messages in [historical, current] {
            let rows = TranscriptRow.rows(for: messages)
            XCTAssertEqual(rows.map(\.id), [first.id, effort.id, answer.id, queued.id, nextEffort.id])
            guard case let .activity(_, userMessageID, entries) = rows[1] else { return XCTFail("Expected tool group") }
            XCTAssertEqual(userMessageID, first.id)
            XCTAssertEqual(entries.map(\.id), [effort.id, result.id])
        }
    }

    func testInterleavedToolEventsStayInOneRowPerPrompt() {
        let user = ChatMessage(role: "user", text: "first")
        let effort = ChatMessage(role: "system", text: "Effort: High")
        let start = ChatMessage(role: "tool", text: "[read] read_file")
        let pending = ChatMessage(role: "user", text: "later", queued: true)
        let partial = ChatMessage(role: "assistant", text: "Проверяю вторую папку")
        let result = ChatMessage(role: "tool", text: "[read] contents")
        let route = ChatMessage(role: "system", text: "Модель: local")
        let other = ChatMessage(role: "tool", text: "[find] find_files")
        let error = ChatMessage(role: "system", text: "Ошибка: нет доступа")
        let next = ChatMessage(role: "user", text: "second")
        let again = ChatMessage(role: "tool", text: "[read] read_file")
        let rows = TranscriptRow.rows(for: [user, effort, start, pending, partial, result, route, other, error, next, again])
        XCTAssertEqual(rows.map(\.id), [user.id, effort.id, partial.id, error.id, next.id, again.id, pending.id])
        guard case let .activity(_, userID, entries) = rows[1] else { return XCTFail("Expected the first turn's actions") }
        XCTAssertEqual(userID, user.id)
        XCTAssertEqual(ActivityDisclosure.label(for: entries), "Действия агента · 2")
        XCTAssertEqual(entries.map(\.id), [effort.id, start.id, result.id, route.id, other.id])
    }

    @MainActor
    func testClickingActivityRowOpensAndClosesDetails() async throws {
        _ = NSApplication.shared
        let entries = [ChatMessage(role: "tool", text: "[1] read_file"),
                       ChatMessage(role: "tool", text: "[1] The file contents\nMore content")]
        let view = NSHostingView(rootView: ActivityDisclosure(entries: entries).frame(width: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = NSView(frame: window.contentLayoutRect)
        window.contentView = canvas
        canvas.addSubview(view)
        window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
        window.orderBack(nil)
        window.makeKey()
        defer { window.orderOut(nil) }
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        let collapsedHeight = view.fittingSize.height
        func click() throws {
            let top = view.isFlipped ? 13.0 : view.bounds.height - 13
            let location = view.convert(NSPoint(x: 120, y: top), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                NSApp.sendEvent(event)
            }
        }
        try click()
        for _ in 0..<50 where view.fittingSize.height <= collapsedHeight {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(view.fittingSize.height, collapsedHeight)
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        try click()
        for _ in 0..<50 where view.fittingSize.height > collapsedHeight {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(view.fittingSize.height, collapsedHeight)
    }
}
