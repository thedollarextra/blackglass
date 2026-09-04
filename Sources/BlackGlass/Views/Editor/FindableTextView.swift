import SwiftUI
import AppKit

/// Plain-text editor backed directly by `NSTextView`, so search matches can
/// be highlighted with real text-storage attributes — a SwiftUI `TextEditor`
/// has no API for painting a background behind arbitrary substrings.
struct FindableTextView: NSViewRepresentable {
    @Binding var text: String
    var searchQuery: String
    @Binding var matchCount: Int
    @Binding var currentMatch: Int
    /// Set to `true` to steal focus and move the caret to the very start;
    /// the representable resets it back to `false` once applied.
    @Binding var requestFocusAtStart: Bool
    var onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.drawsBackground = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            let ranges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = ranges
        }
        context.coordinator.applyHighlights(query: searchQuery, requestedMatch: currentMatch)

        if requestFocusAtStart {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
                requestFocusAtStart = false
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FindableTextView
        weak var textView: NSTextView?
        private var lastQuery: String = ""

        init(_ parent: FindableTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.onTextChange(tv.string)
        }

        /// Recomputes match ranges for `query` against the live text-storage
        /// contents and paints them: current match in a brighter amber,
        /// every other match in translucent yellow. Runs on every SwiftUI
        /// update — cheap enough for note-length documents — so highlights,
        /// the match count, and scroll position always track the latest text.
        func applyHighlights(query: String, requestedMatch: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let full = storage.string as NSString
            let queryChanged = query != lastQuery
            lastQuery = query

            var ranges: [NSRange] = []
            if !query.isEmpty {
                var searchRange = NSRange(location: 0, length: full.length)
                while searchRange.location < full.length {
                    let found = full.range(of: query, options: .caseInsensitive, range: searchRange)
                    if found.location == NSNotFound { break }
                    ranges.append(found)
                    let nextStart = found.location + max(found.length, 1)
                    searchRange = NSRange(location: nextStart, length: full.length - nextStart)
                }
            }

            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: full.length))
            let clampedCurrent = ranges.isEmpty ? 0 : min(max(requestedMatch, 1), ranges.count)
            for (index, range) in ranges.enumerated() {
                let isCurrent = index + 1 == clampedCurrent
                storage.addAttribute(
                    .backgroundColor,
                    value: isCurrent
                        ? NSColor.systemYellow.withAlphaComponent(0.85)
                        : NSColor.systemYellow.withAlphaComponent(0.35),
                    range: range
                )
            }
            storage.endEditing()

            if ranges.count != parent.matchCount {
                DispatchQueue.main.async { [parent] in parent.matchCount = ranges.count }
            }
            if clampedCurrent != requestedMatch || queryChanged {
                DispatchQueue.main.async { [parent] in parent.currentMatch = clampedCurrent }
            }
            if clampedCurrent >= 1, clampedCurrent <= ranges.count {
                textView.scrollRangeToVisible(ranges[clampedCurrent - 1])
            }
        }
    }
}
