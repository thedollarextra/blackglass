import SwiftUI

/// Floating in-document find bar (⌘F), overlaid on the editor's top-trailing
/// corner. Matches are highlighted directly in the text by `FindableTextView`;
/// this just drives the query and lets the user step between them.
struct FindBar: View {
    @Binding var query: String
    var matchCount: Int
    @Binding var currentMatch: Int
    var onClose: () -> Void
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in note", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 160)
                .focused($isFocused)
                .onSubmit { step(1) }
                .onKeyPress(.escape) {
                    onClose()
                    return .handled
                }

            Text(matchCount == 0 ? "No results" : "\(currentMatch) of \(matchCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)
                .lineLimit(1)

            Divider().frame(height: 14)

            Button(action: { step(-1) }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)

            Button(action: { step(1) }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(cornerRadius: 12)
        .fixedSize()
    }

    private func step(_ delta: Int) {
        guard matchCount > 0 else { return }
        let base = currentMatch == 0 ? (delta > 0 ? 0 : 1) : currentMatch
        let zeroBased = ((base - 1 + delta) % matchCount + matchCount) % matchCount
        currentMatch = zeroBased + 1
    }
}
