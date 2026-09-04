import SwiftUI
import AppKit

public struct SidebarView: View {
    @ObservedObject var vaultManager: VaultManager
    @ObservedObject var windowState: WindowState
    @ObservedObject private var settingsStore = SettingsStore.shared
    @State private var isVaultPickerPresented = false
    @FocusState private var searchFieldFocused: Bool
    @State private var pendingDelete: [FileItem]?

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

    /// Flattened, on-screen row order, respecting collapsed folders. Backs
    /// both the `LazyVStack` below and shift-click range selection.
    private var visibleRows: [VaultManager.FlatRow] {
        vaultManager.visibleFlattenedItems(collapsed: windowState.collapsedFolderIDs)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
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
                                        isSelected: windowState.selection.contains(result.fileItem.id)
                                    ) {
                                        windowState.select(result.fileItem)
                                    }
                                    .id(result.id)
                                }
                            }
                        } else {
                            let rows = visibleRows
                            // Computed once per body evaluation rather than
                            // inside the ForEach closure below: that closure
                            // runs once per on-screen row, so mapping `rows`
                            // there re-walked the full (up to ~2,000-item)
                            // flattened tree once per visible row instead of once.
                            let order = rows.map(\.item.id)
                            ForEach(rows) { row in
                                TreeRowView(
                                    item: row.item,
                                    depth: row.depth,
                                    windowState: windowState,
                                    visibleOrder: order,
                                    onDelete: { performDelete($0) },
                                    onRename: { item, title, focusEditor in
                                        let renamed = vaultManager.commitRename(item, to: title, focusEditor: focusEditor)
                                        if renamed.id != item.id {
                                            windowState.remap([item.id: renamed.id])
                                        }
                                        // Unconditional: if the destination path didn't
                                        // change (e.g. the user accepted the pre-filled
                                        // default name as-is), `renamed.id == item.id`
                                        // and the remap above never runs — leaving this
                                        // row's id still equal to `renamingID`, which
                                        // would keep it stuck in the text-field state
                                        // forever since nothing else clears it.
                                        windowState.renamingID = nil
                                    },
                                    onCancelRename: { windowState.renamingID = nil },
                                    onMove: { sources, destination in
                                        let items = sources.compactMap { vaultManager.findInTree(id: $0.standardizedFileURL.path) }
                                        let remap = vaultManager.moveItems(items, to: destination)
                                        windowState.remap(remap)
                                    },
                                    onImport: { sources, destination in
                                        vaultManager.importFiles(sources, into: destination)
                                    }
                                )
                                .id(row.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Clicking empty space below the rows while a rename
                        // is in progress: same reasoning as the click-another-
                        // row case above — force the field to give up first
                        // responder so the pending rename actually commits.
                        if windowState.renamingID != nil {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    }
                    // Empty space below the last row: drop here to move an
                    // item back to the vault's top level, or drop files from
                    // Finder here to import them into the vault's root.
                    .onDrop(of: [.plainText, .fileURL], isTargeted: nil) { providers in
                        guard let active = vaultManager.activeVault else { return false }
                        return handleDrop(providers, destination: active.url) { sources, destination in
                            let items = sources.compactMap { vaultManager.findInTree(id: $0.standardizedFileURL.path) }
                            let remap = vaultManager.moveItems(items, to: destination)
                            windowState.remap(remap)
                        } onImport: { sources, destination in
                            vaultManager.importFiles(sources, into: destination)
                        }
                    }
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

                if let batch = vaultManager.lastDelete {
                    Button(action: { vaultManager.undoLastDelete() }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .help("Undo delete (\(batch.affectedCount) item\(batch.affectedCount == 1 ? "" : "s"))")
                }

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

                if !settingsStore.settings.nativeSearchAlwaysVisible {
                    Button(action: toggleSearch) {
                        Image(systemName: "magnifyingglass")
                            .font(.body)
                            .foregroundStyle(windowState.isSearching ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(windowState.isSearching ? "Close Search (Esc)" : "Search Notes (⌃F)")
                }

                Button(action: { windowState.showGraph.toggle() }) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.body)
                        .foregroundStyle(windowState.showGraph ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .help(windowState.showGraph ? "Close Graph" : "Graph view")

                Button(action: { windowState.showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Settings")
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
        .background {
            Button("Close Search") { closeSearch() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .disabled(!windowState.isSearching)
            Button("Delete Selection") { performDelete(nil) }
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .disabled(windowState.selection.isEmpty || windowState.renamingID != nil || isFilterActive)
        }
        .onChange(of: windowState.isSearching) { _, on in
            if on {
                DispatchQueue.main.async {
                    searchFieldFocused = true
                }
            }
        }
        .onAppear {
            if settingsStore.settings.nativeSearchAlwaysVisible { windowState.isSearching = true }
        }
        .onChange(of: settingsStore.settings.nativeSearchAlwaysVisible) { _, on in
            if on { windowState.isSearching = true }
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \(vaultManager.affectedNoteCount(of: $0)) items?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let pendingDelete { commitDelete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This moves the selected items — and everything inside any selected folders — to the Trash.")
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

    /// With "keep search always open" on, this can't actually close the
    /// search bar — Escape (and the field's own ✕) just clear the query
    /// instead, same as clicking ✕ normally would before also hiding the bar.
    private func closeSearch() {
        let selectedID = windowState.soleSelectedID
        windowState.searchQuery = ""
        searchTask?.cancel()
        searchResults = []
        guard !settingsStore.settings.nativeSearchAlwaysVisible else { return }
        windowState.isSearching = false
        searchFieldFocused = false
        if let selectedID, let selected = vaultManager.findInTree(id: selectedID) {
            windowState.reveal(selected, ancestorFolderIDs: vaultManager.ancestorFolderIDs(of: selected.url))
        }
    }

    private func selectFirstResult() {
        if let first = searchResults.first {
            windowState.select(first.fileItem)
        }
    }

    /// Deletes `item` if given and it isn't part of the current multi-selection,
    /// otherwise deletes the whole selection — Finder's right-click convention.
    /// Confirms first only when more than 10 notes would be affected.
    private func performDelete(_ item: FileItem?) {
        let targets: [FileItem]
        if let item, !windowState.selection.contains(item.id) {
            targets = [item]
        } else {
            targets = windowState.selection.compactMap { vaultManager.findInTree(id: $0) }
        }
        guard !targets.isEmpty else { return }
        if vaultManager.affectedNoteCount(of: targets) > 10 {
            pendingDelete = targets
        } else {
            commitDelete(targets)
        }
    }

    private func commitDelete(_ targets: [FileItem]) {
        let ids = Set(targets.map(\.id))
        vaultManager.deleteItems(targets)
        windowState.discard(ids: ids)
    }
}

/// Dispatches a drop to `onMove` (this app's own newline-joined-paths
/// payload, used for internal drag-to-move within the sidebar) or `onImport`
/// (one or more real file URLs — dragged in from Finder or anywhere else
/// outside the app). Checked in that order: a Finder file is always loadable
/// as a URL, while this app's own drag payload never is (it's a plain
/// string), so URL-loadability alone tells the two apart unambiguously.
/// Shared by every drop target in the sidebar (folder rows and the empty
/// area below the tree, which drops back to the vault root).
func handleDrop(
    _ providers: [NSItemProvider],
    destination: URL,
    onMove: @escaping @Sendable @MainActor ([URL], URL) -> Void,
    onImport: @escaping @Sendable @MainActor ([URL], URL) -> Void
) -> Bool {
    let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
    if !fileProviders.isEmpty {
        // Loaded one at a time (rather than an async Task awaiting an array
        // of them) so nothing but the final, Sendable-safe `[URL]` ever
        // crosses into the `@MainActor` closure that hands off to `onImport`.
        loadFileURLs(fileProviders) { urls in
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                onImport(urls, destination)
            }
        }
        return true
    }

    guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
    _ = provider.loadObject(ofClass: NSString.self) { value, _ in
        guard let text = value as? String else { return }
        let urls = text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            onMove(urls, destination)
        }
    }
    return true
}

/// Loads each provider's `URL` one at a time (not concurrently), threading
/// the accumulated result through the recursion so nothing needs a lock —
/// `NSItemProvider.loadObject`'s completion isn't guaranteed to land on any
/// particular queue, so collecting into a shared array from parallel
/// callbacks would race.
private func loadFileURLs(_ providers: [NSItemProvider], collected: [URL] = [], completion: @escaping ([URL]) -> Void) {
    guard let first = providers.first else {
        completion(collected)
        return
    }
    let rest = Array(providers.dropFirst())
    _ = first.loadObject(ofClass: URL.self) { value, _ in
        loadFileURLs(rest, collected: value.map { collected + [$0] } ?? collected, completion: completion)
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

/// One flat sidebar row — file or folder — indented by `depth`. Rows used to
/// be recursive (a folder's `body` rendered a nested `ForEach` of its
/// children), which meant showing one window's sidebar built the entire
/// ~2,000-note tree as real, non-lazy SwiftUI view state up front; that's
/// what made opening or closing a window sluggish. Flattening the tree once
/// in `SidebarView` and rendering it through a single `LazyVStack` lets
/// SwiftUI build only the rows actually on screen.
public struct TreeRowView: View {
    let item: FileItem
    let depth: Int
    @ObservedObject var windowState: WindowState
    var visibleOrder: [String]
    var onDelete: (FileItem) -> Void
    var onRename: (FileItem, String, Bool) -> Void
    var onCancelRename: () -> Void
    var onMove: @Sendable @MainActor ([URL], URL) -> Void
    var onImport: @Sendable @MainActor ([URL], URL) -> Void
    @State private var draftName = ""
    @State private var isDropTargeted = false

    /// Width reserved for a folder's disclosure chevron. Files reserve the
    /// same width with an invisible spacer, so a file's icon lands in the
    /// same column as a sibling folder's icon rather than under its chevron.
    private static let chevronWidth: CGFloat = 12
    private static let indentUnit: CGFloat = 16

    private var isExpanded: Bool { !windowState.collapsedFolderIDs.contains(item.id) }
    private var isSelected: Bool { windowState.selection.contains(item.id) }
    private var isRenaming: Bool { windowState.renamingID == item.id }

    /// Finder-style click handling: plain click selects just this row, ⌘
    /// toggles it into/out of the selection, ⇧ extends from the anchor.
    private func handleClick() {
        // A SwiftUI tap gesture elsewhere in the sidebar doesn't necessarily
        // resign the in-progress rename field's first-responder status (it's
        // a native NSTextField, not something AppKit's responder chain hears
        // about from a plain gesture) — force it, so the pending rename
        // actually commits instead of silently staying open behind this click.
        if windowState.renamingID != nil, windowState.renamingID != item.id {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            windowState.toggle(item)
        } else if flags.contains(.shift) {
            windowState.extendSelection(to: item, visibleOrder: visibleOrder)
        } else {
            windowState.select(item)
        }
    }

    /// What a drag from this row carries: the whole selection if this row is
    /// part of a multi-selection, otherwise just this row.
    private func dragProvider() -> NSItemProvider {
        let ids = isSelected && windowState.selection.count > 1 ? windowState.selection : [item.id]
        return NSItemProvider(object: ids.joined(separator: "\n") as NSString)
    }

    public var body: some View {
        HStack(spacing: 4) {
            if item.isDirectory {
                Button(action: { windowState.toggleFolder(item) }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.chevronWidth, height: 22)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: Self.chevronWidth, height: 22)
            }

            if isRenaming {
                HStack(spacing: 5) {
                    icon
                    InlineRenameField(
                        text: $draftName,
                        onCommit: { focusEditor in
                            onRename(item, draftName, focusEditor)
                        },
                        onCancel: onCancelRename
                    )
                    .frame(minWidth: 40, maxWidth: .infinity, minHeight: 18)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            } else {
                HStack(spacing: 5) {
                    icon
                    Text(item.displayTitle)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    isSelected ? Color.accentColor.opacity(0.2)
                        : (isDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.4)
                                : (isDropTargeted ? Color.accentColor.opacity(0.7) : Color.clear),
                            lineWidth: isDropTargeted ? 1.5 : 1
                        )
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { windowState.renamingID = item.id }
                .onTapGesture(count: 1, perform: handleClick)
            }
        }
        .padding(.leading, CGFloat(depth) * Self.indentUnit)
        .onAppear { if isRenaming { draftName = item.displayTitle } }
        .onChange(of: windowState.renamingID) { _, newValue in
            if newValue == item.id { draftName = item.displayTitle }
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            if item.isDirectory {
                Divider()
                Button("Expand All") {
                    windowState.collapsedFolderIDs.subtract(item.folderIDsInSubtree)
                }
                Button("Collapse All") {
                    windowState.collapsedFolderIDs.formUnion(item.folderIDsInSubtree)
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                onDelete(item)
            }
        }
        .onDrag(dragProvider)
        .modifier(DropIfDirectory(isDirectory: item.isDirectory, destination: item.url, isTargeted: $isDropTargeted, onMove: onMove, onImport: onImport))
    }

    @ViewBuilder
    private var icon: some View {
        if item.isDirectory {
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "doc.text")
                .font(.callout)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
    }
}

/// Only folders accept drops. Kept as a separate modifier (rather than an
/// `if` inline in `body`) so `.onDrop`'s `isTargeted` binding isn't attached
/// and detached as a row toggles between file and folder rendering.
private struct DropIfDirectory: ViewModifier {
    let isDirectory: Bool
    let destination: URL
    @Binding var isTargeted: Bool
    var onMove: @Sendable @MainActor ([URL], URL) -> Void
    var onImport: @Sendable @MainActor ([URL], URL) -> Void

    func body(content: Content) -> some View {
        if isDirectory {
            content.onDrop(of: [.plainText, .fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers, destination: destination, onMove: onMove, onImport: onImport)
            }
        } else {
            content
        }
    }
}

extension Notification.Name {
    static let liquidNotesToggleEditor = Notification.Name("liquidNotesToggleEditor")
    static let liquidNotesFocusEditor = Notification.Name("liquidNotesFocusEditor")
    static let liquidNotesOpenSettings = Notification.Name("liquidNotesOpenSettings")
    static let liquidNotesFindInNote = Notification.Name("liquidNotesFindInNote")
}
