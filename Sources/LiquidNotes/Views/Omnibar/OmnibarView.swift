import SwiftUI
import AppKit

public struct OmnibarView: View {
    @ObservedObject var vaultManager: VaultManager
    @ObservedObject var windowState: WindowState
    @Binding var isPresented: Bool
    @State private var query: String = ""
    @State private var results: [SearchResult] = []
    @State private var selectedIndex: Int = 0
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Search all notes or jump to file…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onChange(of: query) { _, newQuery in
                        performSearch(newQuery)
                    }
                    .onSubmit { confirmSelection() }
                if !query.isEmpty {
                    Button(action: { searchTask?.cancel(); query = ""; results = [] }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)

            Divider().opacity(0.3)

            if results.isEmpty {
                VStack(spacing: 6) {
                    Text(query.isEmpty ? "Type to search notes in active vault" : "No notes found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(32)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                let isSelected = index == selectedIndex
                                Button(action: { selectResult(result) }) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(result.title)
                                                .font(.headline)
                                            Spacer()
                                            Text(result.fileItem.url.lastPathComponent)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(result.snippet)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selectedIndex) { _, newValue in
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 580)
        .liquidGlass(cornerRadius: 16)
        .padding()
        .onAppear {
            isSearchFocused = true
        }
        .onExitCommand {
            isPresented = false
        }
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    /// Debounced so a fast typist runs one search, not one per keystroke, and
    /// the index work happens off the main actor.
    private func performSearch(_ text: String) {
        searchTask?.cancel()
        guard vaultManager.activeVault != nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            selectedIndex = 0
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let hits = await vaultManager.searchAsync(query: text, limit: 60)
            guard !Task.isCancelled else { return }
            results = hits
            selectedIndex = 0
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    private func confirmSelection() {
        guard results.indices.contains(selectedIndex) else { return }
        selectResult(results[selectedIndex])
    }

    private func selectResult(_ result: SearchResult) {
        let live = vaultManager.findInTree(id: result.fileItem.id) ?? result.fileItem
        windowState.reveal(live, ancestorFolderIDs: vaultManager.ancestorFolderIDs(of: live.url))
        isPresented = false
    }
}
