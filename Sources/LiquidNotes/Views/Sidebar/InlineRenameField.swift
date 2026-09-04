import SwiftUI
import AppKit

struct InlineRenameField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: (_ focusEditor: Bool) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> RenameTextField {
        let field = RenameTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.stringValue = text
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: RenameTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        if nsView.currentEditor() == nil, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommit: (Bool) -> Void
        var onCancel: () -> Void
        private var didFinish = false

        init(text: Binding<String>, onCommit: @escaping (Bool) -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            let movement = (obj.userInfo?["NSTextMovement"] as? NSNumber)?.intValue ?? 0
            finish(focusEditor: movement == NSReturnTextMovement)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish(focusEditor: true)
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                guard !didFinish else { return true }
                didFinish = true
                onCancel()
                return true
            }
            return false
        }

        /// Vetoes exactly one resignation attempt that lands in the same
        /// run-loop turn the field claims first responder in (see
        /// `RenameTextField.suppressNextResignation`). Something else in the
        /// window — most often the editor pane appearing for the just-created
        /// note in the same update — can also request first responder that
        /// same turn, which used to end the rename before the user had even
        /// seen it start. A real click elsewhere or Tab always arrives on a
        /// later turn, so this never blocks genuine user-driven commits.
        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            guard let field = control as? RenameTextField, field.suppressNextResignation else { return true }
            field.suppressNextResignation = false
            return false
        }

        private func finish(focusEditor: Bool) {
            guard !didFinish else { return }
            didFinish = true
            onCommit(focusEditor)
        }
    }
}

final class RenameTextField: NSTextField {
    private var didAttemptFocus = false
    fileprivate var suppressNextResignation = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didAttemptFocus else { return }
        didAttemptFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.suppressNextResignation = true
            guard self.window?.makeFirstResponder(self) == true else {
                self.suppressNextResignation = false
                return
            }
            self.currentEditor()?.selectAll(nil)
            // Only the very next resignation attempt is guarded — anything
            // after this turn is a genuine click-away or Tab and must end
            // the rename as usual.
            DispatchQueue.main.async { [weak self] in
                self?.suppressNextResignation = false
            }
        }
    }
}
