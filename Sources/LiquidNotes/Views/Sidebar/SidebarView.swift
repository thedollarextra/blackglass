import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                                    vaultManager: vaultManager
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
                    .modifier(RootDropTarget(vaultManager: vaultManager, windowState: windowState))
                }
                .blocksWindowDrag()
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

            // A drop that imported nothing used to look identical to one that
            // worked, so say what actually happened.
            if let summary = vaultManager.lastImportSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .transition(.opacity)
                    .task(id: summary) {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        guard !Task.isCancelled else { return }
                        vaultManager.lastImportSummary = nil
                    }
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
                    .help(windowState.isSearching
                          ? "Close Search (Esc)"
                          : (settingsStore.settings.commandKSearch == .sidebar
                             ? "Search Notes (⌃F, ⌘K)"
                             : "Search Notes (⌃F)"))
                }

                Button(action: { windowState.showOmnibar.toggle() }) {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.body)
                        .foregroundStyle(windowState.showOmnibar ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .help(settingsStore.settings.commandKSearch == .omnisearch
                      ? "Omnisearch (⌘K)"
                      : "Omnisearch")

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

/// Every drop target in the tree — folder rows, file rows (which land in the
/// containing folder), and the area below the tree (the vault root).
///
/// A `DropDelegate` rather than `onDrop(of:isTargeted:)` because only a
/// delegate gets `validateDrop`. Without it the system lights up any target
/// that merely accepts the *type*, so dropping a folder into its own
/// descendant looked perfectly legal and then silently did nothing.
struct TreeDropDelegate: DropDelegate {
    /// The folder the drop lands in — for a file row, its parent.
    let destination: URL
    let vaultManager: VaultManager
    let windowState: WindowState
    /// The row this target belongs to, if any. `nil` for the area below the
    /// tree, which only ever appends at the vault root.
    var row: FileItem?
    var rowHeight: CGFloat = 28

    /// Where in a row the cursor is: near an edge means "put it between these
    /// two rows", the middle of a folder means "put it inside".
    enum Zone {
        case before
        case into
        case after
    }

    /// A file row has no inside, so it splits cleanly in half; a folder keeps
    /// a generous middle so dropping *into* it stays the easy target.
    private func zone(_ info: DropInfo) -> Zone {
        guard let row else { return .into }
        let y = info.location.y
        guard row.isDirectory else { return y < rowHeight / 2 ? .before : .after }
        let edge = max(4, min(8, rowHeight * 0.25))
        if y < edge { return .before }
        if y > rowHeight - edge { return .after }
        return .into
    }

    /// Siblings of `row`, in the order the tree shows them.
    private var siblings: [FileItem] {
        guard let row else { return [] }
        let parent = row.url.deletingLastPathComponent().standardizedFileURL
        if parent.path == vaultManager.activeVault?.url.standardizedFileURL.path {
            return vaultManager.fileTree
        }
        return vaultManager.findInTree(id: parent.path)?.children ?? []
    }

    /// Folder the drop actually lands in, given where in the row it is.
    /// A file row's `destination` is already its parent, and `zone` never
    /// returns `.into` for one, so both branches agree there.
    private func resolvedDestination(_ info: DropInfo) -> URL {
        guard let row else { return destination }
        switch zone(info) {
        case .into: return destination
        case .before, .after: return row.url.deletingLastPathComponent()
        }
    }

    /// The name the dragged items should be placed in front of — nil appends.
    private func insertBeforeName(_ info: DropInfo) -> String? {
        guard let row else { return nil }
        switch zone(info) {
        case .into: return nil
        case .before: return row.name
        case .after:
            let names = siblings.map(\.name)
            guard let i = names.firstIndex(of: row.name), i + 1 < names.count else { return nil }
            return names[i + 1]
        }
    }

    /// Rejected outright so a drop of photos or apps shows a "no" cursor
    /// rather than a welcoming highlight that imports nothing. Deliberately a
    /// blocklist: a `.md` file's UTI depends on which apps are installed —
    /// it can arrive as plain text, as `net.daringfireball.markdown`, or as
    /// bare `public.data` — so an allowlist would reject real notes. Anything
    /// that slips through still meets the extension check in `importFiles`,
    /// which now reports what it skipped.
    private static let rejectedTypes: [UTType] = [.image, .movie, .audio, .application, .archive, .pdf]
    private static let textLikeTypes: [UTType] = [.plainText, .text, .folder]

    func validateDrop(info: DropInfo) -> Bool {
        // Our own payload settles it: the drag carries the real file too, so
        // "has a file URL" no longer means the drag came from outside.
        if !info.hasItemsConforming(to: [TreeDragPayload.type]) {
            if info.hasItemsConforming(to: [.fileURL]) {
                if !info.hasItemsConforming(to: Self.textLikeTypes),
                   info.hasItemsConforming(to: Self.rejectedTypes) {
                    return false
                }
                return true
            }
        }
        if !windowState.draggingIDs.isEmpty {
            // A reorder within a folder is legal even though the file doesn't
            // go anywhere on disk, so only an into-drop has to clear the
            // same-folder no-op bar.
            let dest = resolvedDestination(info)
            if zone(info) != .into, let row, !windowState.draggingIDs.contains(row.id) {
                return windowState.draggingIDs.contains { canAccept(id: $0, into: dest, allowSameFolder: true) }
            }
            return windowState.draggingIDs.contains { canAccept(id: $0, into: dest, allowSameFolder: false) }
        }
        // A drag from another window: its IDs live in that window's state, so
        // legality can't be settled here. `moveItems` refuses illegal moves
        // anyway once the payload resolves.
        return info.hasItemsConforming(to: [TreeDragPayload.type])
    }

    /// Also where the hover feedback is decided: `dropEntered` only fires
    /// once, but which zone the cursor is in changes as it moves down a row.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Assigned only on an actual change: this fires on every mouse move,
        // and republishing the same value would redraw the whole tree each
        // time the cursor twitched.
        switch zone(info) {
        case .into:
            let id = resolvedDestination(info).standardizedFileURL.path
            if windowState.dropInsertion != nil { windowState.dropInsertion = nil }
            if windowState.dropTargetFolderID != id { windowState.dropTargetFolderID = id }
        case .before, .after:
            let insertion = row.map {
                WindowState.DropInsertion(rowID: $0.id, below: zone(info) == .after)
            }
            if windowState.dropTargetFolderID != nil { windowState.dropTargetFolderID = nil }
            if windowState.dropInsertion != insertion { windowState.dropInsertion = insertion }
        }
        // Internal drags are moves, not copies — without this the system
        // shows a "+" copy badge for something that doesn't copy.
        return DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move)
    }

    func dropEntered(info: DropInfo) {
        let id = destination.standardizedFileURL.path
        windowState.dropTargetFolderID = id
        // Spring-loaded folders: hold a drag over a collapsed folder and it
        // opens, so reaching a subfolder doesn't mean dropping, expanding,
        // and picking the drag back up.
        guard windowState.collapsedFolderIDs.contains(id) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard windowState.dropTargetFolderID == id else { return }
            windowState.collapsedFolderIDs.remove(id)
        }
    }

    func dropExited(info: DropInfo) {
        if windowState.dropTargetFolderID == destination.standardizedFileURL.path {
            windowState.dropTargetFolderID = nil
        }
        if let row, windowState.dropInsertion?.rowID == row.id {
            windowState.dropInsertion = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        windowState.dropTargetFolderID = nil
        windowState.dropInsertion = nil
        let destination = resolvedDestination(info)
        let beforeName = insertBeforeName(info)
        let vaultManager = self.vaultManager
        let windowState = self.windowState

        let internalProviders = info.itemProviders(for: [TreeDragPayload.type])
        let fileProviders = internalProviders.isEmpty
            ? info.itemProviders(for: [.fileURL]).filter { $0.canLoadObject(ofClass: URL.self) }
            : []
        if !fileProviders.isEmpty {
            // Loaded one at a time (rather than an async Task awaiting an
            // array of them) so nothing but the final, Sendable-safe `[URL]`
            // ever crosses into the `@MainActor` closure below.
            loadFileURLs(fileProviders) { urls in
                guard !urls.isEmpty else { return }
                Task { @MainActor in
                    vaultManager.importFiles(urls, into: destination)
                }
            }
            return true
        }

        guard let provider = internalProviders.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: TreeDragPayload.type.identifier) { data, _ in
            guard let data else { return }
            let ids = TreeDragPayload.decode(data)
            guard !ids.isEmpty else { return }
            Task { @MainActor in
                windowState.draggingIDs = []
                let items = ids.compactMap { vaultManager.findInTree(id: $0) }
                windowState.remap(vaultManager.reorderItems(items, into: destination, before: beforeName))
            }
        }
        return true
    }

    /// Whether one dragged item could actually land here — the same three
    /// refusals `moveItems` makes, checked up front so an illegal target
    /// never highlights in the first place.
    private func canAccept(id: String, into destination: URL, allowSameFolder: Bool) -> Bool {
        let source = URL(fileURLWithPath: id).standardizedFileURL
        let dest = destination.standardizedFileURL
        guard source.path != dest.path else { return false }
        guard !dest.path.hasPrefix(source.path + "/") else { return false }
        return allowSameFolder || source.deletingLastPathComponent().path != dest.path
    }
}

/// The tree's own drag payload: the dragged rows' IDs, which are absolute
/// paths. JSON rather than newline-joined text because `\n` is legal in a
/// macOS filename and one such name corrupted the whole payload.
enum TreeDragPayload {
    /// A type of our own, declared in Info.plist, rather than plain text.
    /// The drag also carries the real file so it can be dropped into Finder
    /// or Mail — which means "is this a file URL?" no longer distinguishes an
    /// internal move from an external import, and this does.
    static let type = UTType(exportedAs: "com.liquidnotes.tree-items", conformingTo: .data)

    static func encode(_ ids: [String]) -> Data {
        (try? JSONEncoder().encode(ids)) ?? Data()
    }

    static func decode(_ data: Data) -> [String] {
        (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// What a drag from the tree carries: our own item list, plus the file
    /// itself so other apps get something useful. Only the first file, since
    /// SwiftUI's `onDrag` allows one provider per row — a multi-row drag still
    /// moves everything *inside* the app, where the item list is what counts.
    static func provider(for ids: [String], primary: URL) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: primary) ?? NSItemProvider()
        let payload = encode(ids)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }
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
    @ObservedObject var vaultManager: VaultManager
    @State private var draftName = ""
    @State private var rowHeight: CGFloat = 28

    /// A drop lands in this row's folder — either because the cursor is on
    /// the folder itself, or on one of the files inside it.
    private var isDropTargeted: Bool {
        item.isDirectory && windowState.dropTargetFolderID == item.id
    }

    /// An insertion line is being drawn against this row, and on which edge.
    private var insertionEdge: Alignment? {
        guard let insertion = windowState.dropInsertion, insertion.rowID == item.id else { return nil }
        return insertion.below ? .bottom : .top
    }

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
        // Sorted so a multi-item drag is deterministic — `selection` is a Set,
        // and its order decided which item won a " 2" suffix on a collision.
        let ids = (isSelected && windowState.selection.count > 1
                   ? Array(windowState.selection)
                   : [item.id]).sorted()
        // Published as well as carried in the payload: `validateDrop` has to
        // answer synchronously and can't read the payload.
        windowState.draggingIDs = ids
        // A drag cancelled outside any target never reports an exit, so clear
        // any highlight left over from last time rather than stranding it.
        windowState.dropTargetFolderID = nil
        windowState.dropInsertion = nil
        return TreeDragPayload.provider(for: ids, primary: item.url)
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
                if vaultManager.hasManualOrder(item.url) {
                    Button("Sort by Name") {
                        vaultManager.clearManualOrder(of: item.url)
                    }
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                onDelete(item)
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { rowHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, height in rowHeight = height }
            }
        }
        .overlay(alignment: insertionEdge ?? .top) {
            if insertionEdge != nil {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.leading, CGFloat(depth) * Self.indentUnit + Self.chevronWidth)
                    .allowsHitTesting(false)
            }
        }
        // Not while renaming, or the text field being typed into can be
        // dragged out from under the cursor.
        .modifier(DraggableUnlessRenaming(isRenaming: isRenaming, provider: dragProvider))
        // Every row is a target, not just folders: dropping onto a note puts
        // the item in that note's folder. Previously file rows had no target
        // at all, so the drop fell through to the container and silently
        // moved the item to the vault root from anywhere in the tree.
        .onDrop(of: [TreeDragPayload.type, .fileURL], delegate: TreeDropDelegate(
            destination: item.isDirectory ? item.url : item.url.deletingLastPathComponent(),
            vaultManager: vaultManager,
            windowState: windowState,
            row: item,
            rowHeight: rowHeight
        ))
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

private struct DraggableUnlessRenaming: ViewModifier {
    let isRenaming: Bool
    let provider: () -> NSItemProvider

    func body(content: Content) -> some View {
        if isRenaming {
            content
        } else {
            content.onDrag(provider)
        }
    }
}

/// Drops onto the area below the tree, which land at the vault's top level.
/// A modifier rather than an inline `if` so the target isn't attached and
/// detached as the active vault changes.
private struct RootDropTarget: ViewModifier {
    @ObservedObject var vaultManager: VaultManager
    @ObservedObject var windowState: WindowState

    func body(content: Content) -> some View {
        if let active = vaultManager.activeVault {
            content
                .onDrop(of: [TreeDragPayload.type, .fileURL], delegate: TreeDropDelegate(
                    destination: active.url,
                    vaultManager: vaultManager,
                    windowState: windowState
                ))
                .overlay {
                    // The root has no row of its own to light up.
                    if windowState.dropTargetFolderID == active.url.standardizedFileURL.path {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                            .padding(.horizontal, 4)
                            .allowsHitTesting(false)
                    }
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
