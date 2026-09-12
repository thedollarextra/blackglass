import SwiftUI
import AppKit

struct InlineRenameField: NSViewRepresentable {
    @Binding var text: String
    /// Defaulted so the sidebar's rows are unaffected. The editor header
    /// renames with the same field and has to keep its heavier heading font,
    /// or the title visibly shrinks the moment it's double-clicked.
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
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
        field.font = font
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.stringValue = text
        field.delegate = context.coordinator
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ nsView: RenameTextField, context: Context) {
        if nsView.font != font { nsView.font = font }
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        if nsView.currentEditor() == nil, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommit: (Bool) -> Void
        var onCancel: () -> Void
        weak var field: RenameTextField?
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

        /// Vetoes exactly one same-tick attempt to pull focus away from the
        /// field right as it claims first responder (see
        /// `RenameTextField.claimFocus`) — something else, most likely the
        /// editor pane appearing for the freshly created note, otherwise
        /// sometimes wins that race and the rename never gets typed into. A
        /// real click elsewhere or Enter always lands on a later run-loop
        /// tick, once `justClaimedFocus` has cleared, so those still end
        /// editing normally.
        func textShouldEndEditing(_ textObject: NSText) -> Bool {
            !(field?.justClaimedFocus ?? false)
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

        private func finish(focusEditor: Bool) {
            guard !didFinish else { return }
            didFinish = true
            onCommit(focusEditor)
        }
    }
}

final class RenameTextField: NSTextField {
    private var didStealFocus = false
    /// True only for the run-loop tick in which this field claims first
    /// responder. `Coordinator.textShouldEndEditing` uses this to veto a
    /// same-tick attempt to steal focus back; cleared on the next tick so a
    /// later, genuine resign (real click elsewhere, Enter) isn't affected.
    fileprivate var justClaimedFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didStealFocus else { return }
        didStealFocus = true
        DispatchQueue.main.async { [weak self] in
            self?.claimFocus()
        }
    }

    private func claimFocus() {
        justClaimedFocus = true
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
        DispatchQueue.main.async { [weak self] in
            self?.justClaimedFocus = false
        }
    }
}
