import AppKit
import SwiftUI

/// Only the message editor owns Return. Sheets and popovers retain their native key handling.
final class ComposerTextView: NSTextView {
    var submit: () -> Void = {}
    private let draftUndo = UndoManager()
    override var undoManager: UndoManager? { draftUndo }

    func showDraft(_ draft: String) {
        guard string != draft else { return }
        string = draft
        setSelectedRange(NSRange(location: draft.utf16.count, length: 0))
        draftUndo.removeAllActions()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard isEditable, !hasMarkedText(), event.keyCode == 36 || event.keyCode == 76 else {
            super.keyDown(with: event)
            return
        }
        switch modifiers {
        case [], .command:
            if !event.isARepeat { submit() }
        case .shift:
            insertNewline(nil)
        default:
            super.keyDown(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { focusAfterLayout() }
    }

    func focusAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditable, let window = self.window, window.attachedSheet == nil else { return }
            window.makeFirstResponder(self)
        }
    }
}

struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var updateText: ((String) -> Void)?

        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { updateText?(editor.string) }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = ComposerTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .labelColor
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Сообщение агенту")
        editor.setAccessibilityHelp("Enter отправляет сообщение. Shift-Enter добавляет строку.")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.updateText = { text = $0 }
        editor.submit = { [weak editor] in
            submit()
            editor?.showDraft(text)
        }
        editor.showDraft(text)
        let wasEditable = editor.isEditable
        editor.isEditable = editable
        if editable && !wasEditable { editor.focusAfterLayout() }
    }
}
