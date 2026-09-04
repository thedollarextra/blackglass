import SwiftUI
import AppKit

public struct SidebarView: View {
    @ObservedObject var vaultManager: VaultManager
    @ObservedObject var windowState: WindowState
    @State private var isVaultPickerPresented = false
    @FocusState private var searchFieldFocused: Bool

    @State private var searchResults: [SearchResult] = []
    @State private var searchTask: Task<Void, Never>?

    /// Debounced and off the main actor. This used to be a computed property,
    /// so every sidebar redraw re-ran a full-vault search.
    private func updateSearchResults(_ text: String) {
        searchTask?.cancel()
        guard windowState.isSearching, vaultManager.activeVault != nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let hits = await vaultManager.searchAsync(query: text, limit: 60)
            guard !Task.isCancelled else { return }
            searchResults = hits
        }
    }

    private var isFilterActive: Bool {
        windowState.isSearching && !windowState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy: a plain VStack over a vault's full (expanded-by-
                    // default) file tree had to materialize every row up
                    // front, which is what made opening a large vault's
                    // sidebar slow to begin with.
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if isFilterActive {
                            if searchResults.isEmpty {
                                Text("No notes found")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 12)
                            } else {
                                ForEach(searchResults) { result in
                                    SearchResultRow(
                                        result: result,
                                        isSelected: windowState.soleSelectedID == result.fileItem.id
                                    ) {
                                        windowState.select(result.fileItem)
                                    }
                                    .id(result.id)
                                }
                            }
                        } else {
                            ForEach(vaultManager.fileTree) { item in
                                FileTreeNodeView(
                                    item: item,
                                    selectedID: windowState.soleSelectedID,
                                    onSelect: { windowState.select($0) },
                                    renamingID: windowState.renamingID,
                                    collapsedFolderIDs: windowState.collapsedFolderIDs,
                                    onToggleFolder: { windowState.toggleFolder($0) },
                                    onDelete: { item in
                                        vaultManager.deleteItems([item])
                                        windowState.discard(ids: [item.id])
                                    },
                                    onRename: { item, title, focusEditor in
                                        let renamed = vaultManager.commitRename(item, to: title, focusEditor: focusEditor)
                                        windowState.remap([item.id: renamed.id])
                                        windowState.renamingID = nil
                                    },
                                    onCancelRename: { windowState.cancelRename() }
                                )
                                .id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .modifier(TrafficLightScrollEdge())
                .onChange(of: windowState.renamingID) { _, id in
                    if let id {
                        DispatchQueue.main.async {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .onChange(of: windowState.pendingReveal) { _, reveal in
                    guard let reveal else { return }
                    // Wait until search results are swapped for the live tree
                    // and ancestor folders have expanded.
                    DispatchQueue.main.async {
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(reveal.itemID, anchor: .center)
                            }
                            if windowState.pendingReveal == reveal {
                                windowState.pendingReveal = nil
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if windowState.isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search notes", text: $windowState.searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFieldFocused)
                        .onSubmit { selectFirstResult() }
                        .onChange(of: windowState.searchQuery) { _, text in
                            updateSearchResults(text)
                        }
                    Button(action: closeSearch) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close search")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .onExitCommand(perform: closeSearch)
            }

            Divider().opacity(0.3)

            HStack {
                Button(action: { isVaultPickerPresented.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.gearshape")
                            .foregroundStyle(.tint)
                        Text(vaultManager.activeVault?.name ?? "No Vault")
                            .font(.callout)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isVaultPickerPresented, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Switch Vault")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 6)

                        ForEach(vaultManager.vaults) { vault in
                            Button(action: {
                                vaultManager.selectVault(vault)
                                isVaultPickerPresented = false
                            }) {
                                HStack {
                                    Text(vault.name)
                                        .font(.body)
                                    Spacer()
                                    if vault.id == vaultManager.activeVault?.id {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }

                        Divider()

                        Button(action: {
                            isVaultPickerPresented = false
                            windowState.showManageVaults = true
                        }) {
                            HStack {
                                Image(systemName: "slider.horizontal.3")
                                Text("Manage Vaults…")
                            }
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .frame(minWidth: 200)
                }

                Spacer()

                Button(action: { windowState.requestNewNote(in: vaultManager) }) {
                    Image(systemName: "square.and.pencil")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("New Note (⌘N)")

                Button(action: { vaultManager.refreshAll() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Refresh notebook and rebuild index")

                Button(action: toggleSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.body)
                        .foregroundStyle(windowState.isSearching ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .help(windowState.isSearching ? "Close Search (Esc)" : "Search Notes (⌃F)")

                Button(action: { windowState.showGraph.toggle() }) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.body)
                        .foregroundStyle(windowState.showGraph ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .help(windowState.showGraph ? "Close Graph" : "Graph view")

                Button(action: {
                    NotificationCenter.default.post(name: .liquidNotesOpenSettings, object: nil)
                }) {
                    Image(systemName: "gearshape")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Settings")
                .keyboardShortcut(",", modifiers: [.command])
            }
            .padding(10)
            .background(.ultraThinMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            VisualEffectBlur(material: .sidebar)
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            ProgressiveTitlebarGlass()
                .frame(height: WindowChrome.trafficLightGlassHeight)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            WindowTrafficLights()
                .padding(.top, 11)
                .padding(.leading, 16)
        }
        .ignoresSafeArea(edges: .top)
        .onReceive(NotificationCenter.default.publisher(for: .liquidNotesNewNote)) { _ in
            windowState.requestNewNote(in: vaultManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .liquidNotesOpenSearch)) { _ in
            openSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .liquidNotesToggleSearch)) { _ in
            openSearch()
        }
        .background {
            Button("Close Search") { closeSearch() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .disabled(!windowState.isSearching)
        }
        .onChange(of: windowState.isSearching) { _, on in
            if on {
                DispatchQueue.main.async {
                    searchFieldFocused = true
                }
            }
        }
    }

    private func toggleSearch() {
        if windowState.isSearching {
            closeSearch()
        } else {
            openSearch()
        }
    }

    private func openSearch() {
        windowState.isSearching = true
        DispatchQueue.main.async {
            searchFieldFocused = true
        }
    }

    private func closeSearch() {
        let selectedID = windowState.soleSelectedID
        windowState.isSearching = false
        windowState.searchQuery = ""
        searchTask?.cancel()
        searchResults = []
        searchFieldFocused = false
        if let selectedID, let selected = vaultManager.findInTree(id: selectedID) {
            windowState.revealInTree(selected, in: vaultManager)
        }
    }

    private func selectFirstResult() {
        if let first = searchResults.first {
            windowState.select(first.fileItem)
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.callout)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    Text(result.title)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                }
                if !result.snippet.isEmpty {
                    Text(result.snippet)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 22)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

public struct FileTreeNodeView: View {
    let item: FileItem
    var selectedID: String?
    var onSelect: (FileItem) -> Void
    var renamingID: String?
    var collapsedFolderIDs: Set<String>
    var onToggleFolder: (FileItem) -> Void
    var onDelete: (FileItem) -> Void
    var onRename: (FileItem, String, Bool) -> Void
    var onCancelRename: () -> Void
    @State private var draftName = ""

    private var isExpanded: Bool { !collapsedFolderIDs.contains(item.id) }

    public var body: some View {
        if item.isDirectory {
            VStack(alignment: .leading, spacing: 2) {
                let isSelected = selectedID == item.id
                HStack(spacing: 2) {
                    Button(action: { onToggleFolder(item) }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 22)
                    }
                    .buttonStyle(.plain)

                    Button(action: { onSelect(item) }) {
                        HStack(spacing: 5) {
                            Image(systemName: isExpanded ? "folder.fill" : "folder")
                                .foregroundStyle(.secondary)
                            Text(item.displayTitle)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                }

                if isExpanded, let children = item.children {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(children) { child in
                            FileTreeNodeView(
                                item: child,
                                selectedID: selectedID,
                                onSelect: onSelect,
                                renamingID: renamingID,
                                collapsedFolderIDs: collapsedFolderIDs,
                                onToggleFolder: onToggleFolder,
                                onDelete: onDelete,
                                onRename: onRename,
                                onCancelRename: onCancelRename
                            )
                            .id(child.id)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        } else {
            fileRow
        }
    }

    private var isRenaming: Bool { renamingID == item.id }

    private var fileRow: some View {
        let isSelected = selectedID == item.id
        return HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.callout)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            if isRenaming {
                InlineRenameField(
                    text: $draftName,
                    onCommit: { focusEditor in
                        onRename(item, draftName, focusEditor)
                    },
                    onCancel: onCancelRename
                )
                .frame(minWidth: 40, maxWidth: .infinity, minHeight: 18)
            } else {
                Text(item.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isRenaming {
                onSelect(item)
            }
        }
        .onAppear {
            if isRenaming { draftName = item.displayTitle }
        }
        .onChange(of: renamingID) { _, newValue in
            if newValue == item.id {
                draftName = item.displayTitle
            }
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                onDelete(item)
            }
        }
    }
}

extension Notification.Name {
    static let liquidNotesNewNote = Notification.Name("liquidNotesNewNote")
    static let liquidNotesToggleEditor = Notification.Name("liquidNotesToggleEditor")
    static let liquidNotesFocusEditor = Notification.Name("liquidNotesFocusEditor")
    static let liquidNotesToggleSearch = Notification.Name("liquidNotesToggleSearch")
    static let liquidNotesOpenSearch = Notification.Name("liquidNotesOpenSearch")
    static let liquidNotesOpenSettings = Notification.Name("liquidNotesOpenSettings")
    static let liquidNotesFindInNote = Notification.Name("liquidNotesFindInNote")
}
