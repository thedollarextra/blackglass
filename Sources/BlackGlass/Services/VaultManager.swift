import Foundation
import Combine

@MainActor
public final class VaultManager: ObservableObject {
    @Published public var vaults: [Vault] = []
    @Published public var activeVault: Vault?
    /// Written only through `setFileTree`, which is what keeps the flattened
    /// row cache behind `visibleFlattenedItems` from going stale — hence
    /// `private(set)`, so a direct assignment can't quietly bypass it.
    @Published public private(set) var fileTree: [FileItem] = []
    /// Last trashed batch, restorable via `undoLastDelete()`. Shared across
    /// windows since it mirrors a real filesystem action, not window UI state.
    @Published public private(set) var lastDelete: DeletedBatch?
    /// Result of the most recent import, so a drop that quietly skipped
    /// everything (40 photos onto the tree, say) says so instead of just
    /// appearing to do nothing. Cleared by the sidebar after it's shown.
    @Published public var lastImportSummary: String?
    private let treeOrder = TreeOrderStore()

    public struct TreeReveal: Equatable {
        public let itemID: String
        public let nonce: UUID
    }

    public struct DeletedBatch {
        public struct Entry {
            let original: URL
            let trashed: URL
            let isDirectory: Bool
        }
        var entries: [Entry]
        /// Notes affected (recursively, for directories) — shown in the Undo tooltip.
        public var affectedCount: Int
    }

    public let searchIndex = SearchIndex()
    let wikiIndex = WikiIndex()
    public let indexer: IndexCoordinator
    private let configURL: URL
    /// Deliberately still the old name — it's a UserDefaults key, and
    /// renaming it would forget which vault an existing install had open.
    private let lastVaultKey = "LiquidNotes.activeVaultID"

    /// Last graph built per vault. `GraphView` is torn down and rebuilt every
    /// time Graph mode is toggled off and on, which used to mean a fresh
    /// vault walk + link parse of every note on each reopen; caching here lets
    /// a same-session reopen skip straight to laying out known nodes/edges.
    /// Dropped on any structural change (create/delete/move/rename), on the
    /// sidebar's manual refresh, and on a note save — a save can add or remove
    /// links, and a graph that silently omits a link you just wrote is worse
    /// than one that takes a moment to reopen.
    private var graphCache: [UUID: GraphData] = [:]

    func cachedGraph(for vault: Vault) -> GraphData? {
        graphCache[vault.id]
    }

    func cacheGraph(_ data: GraphData, for vault: Vault) {
        graphCache[vault.id] = data
    }

    private func invalidateGraphCache() {
        guard let active = activeVault else { return }
        graphCache[active.id] = nil
    }

    /// Last result of `visibleFlattenedItems`, keyed by the collapsed-folder
    /// set it was built for. Dropped whenever the tree itself changes.
    private var flattenedCache: (collapsed: Set<String>, rows: [FlatRow])?

    /// Last whole-tree `findInTree` hit. Several view bodies resolve the same
    /// selected id on every redraw, and each miss walks the entire vault.
    private var lastFound: FileItem?

    /// The only place `fileTree` is assigned, so neither cache can outlive the
    /// tree it was derived from.
    private func setFileTree(_ items: [FileItem]) {
        flattenedCache = nil
        lastFound = nil
        fileTree = items
    }

    public init() {
        self.indexer = IndexCoordinator(search: searchIndex, wiki: wikiIndex)
        self.configURL = AppSupport.folder.appendingPathComponent("vaults.json")

        loadVaults()
        ensureDefaultVaultIfNeeded()
    }

    public func loadVaults() {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode([Vault].self, from: data),
              !decoded.isEmpty else { return }
        self.vaults = decoded
        if let stored = UserDefaults.standard.string(forKey: lastVaultKey),
           let id = UUID(uuidString: stored),
           let match = decoded.first(where: { $0.id == id }) {
            self.activeVault = match
        } else {
            self.activeVault = decoded.first
        }
        refreshFileTree()
        rebuildIndex()
    }

    public func saveVaults() {
        guard let data = try? JSONEncoder().encode(vaults) else { return }
        try? data.write(to: configURL, options: [.atomic])
    }

    public func selectVault(_ vault: Vault) {
        self.activeVault = vault
        indexer.clear()
        UserDefaults.standard.set(vault.id.uuidString, forKey: lastVaultKey)
        refreshFileTree()
        rebuildIndex()
    }

    public func addVault(name: String, path: String) {
        if let existing = vaults.first(where: { $0.path == path }) {
            selectVault(existing)
            return
        }
        let newVault = Vault(name: name, path: path)
        vaults.append(newVault)
        saveVaults()
        selectVault(newVault)
    }

    public func removeVault(_ vault: Vault) {
        vaults.removeAll { $0.id == vault.id }
        graphCache[vault.id] = nil
        saveVaults()
        if activeVault?.id == vault.id {
            if let first = vaults.first {
                selectVault(first)
            } else {
                activeVault = nil
                setFileTree([])
                UserDefaults.standard.removeObject(forKey: lastVaultKey)
            }
        }
    }

    /// Reload the sidebar tree only. Creating, renaming and deleting notes go
    /// through the incremental index hooks instead of a full reindex.
    public func refreshFileTree() {
        guard let active = activeVault, active.exists else {
            setFileTree([])
            indexer.clear()
            return
        }
        setFileTree(loadDirectory(at: active.url))
    }

    /// Full reindex of the active vault. Only on vault switch, launch, or the
    /// explicit Rebuild button in Settings.
    public func rebuildIndex() {
        guard let active = activeVault, active.exists else {
            indexer.clear()
            return
        }
        indexer.rebuild(vault: active.url, name: active.name)
    }

    /// Sidebar refresh: reload the tree and re-scan from disk, for edits made
    /// outside BlackGlass.
    public func refreshAll() {
        invalidateGraphCache()
        refreshFileTree()
        rebuildIndex()
    }

    /// True while the index is dropped because nothing needs it.
    public private(set) var indexSuspended = false

    /// No window is open. With the web server off, nothing can query the index,
    /// so hand its memory back; a rebuild takes a fraction of a second. The
    /// graph cache only ever serves the native Graph view, so it goes back
    /// regardless of server state — nothing else reads it.
    ///
    /// The file tree goes back regardless of server state too. It used to be
    /// tied to the index's `!serverRunning` guard, which meant a menu-bar-only
    /// session with the server on held every `FileItem` in the vault — two
    /// strings, a URL and a child array each — for nobody: the only thing that
    /// reads `fileTree` without a window is `/api/tree`, and every server
    /// handler that touches the tree calls `refreshFileTree()` first anyway.
    public func suspendIndexIfUnused(serverRunning: Bool) {
        graphCache.removeAll()
        guard activeVault != nil else { return }
        if !fileTree.isEmpty { setFileTree([]) }
        if !serverRunning, !indexSuspended {
            indexer.clear()
            indexSuspended = true
        }
        BlackGlassMemory.releaseIdle()
    }

    /// Invariant this restores: a window is on screen, so the tree must be
    /// loaded. Checking `fileTree` rather than only `indexSuspended` matters
    /// because the suspend path drops the tree even when it leaves the index
    /// resident for the server — without this the first sidebar after a
    /// menu-bar-only stretch would render empty.
    public func resumeIndexIfSuspended() {
        guard let active = activeVault else { return }
        if indexSuspended {
            indexSuspended = false
            refreshFileTree()
            rebuildIndex()
        } else if fileTree.isEmpty, active.exists {
            refreshFileTree()
        }
    }

    func flattenNotes(_ items: [FileItem]? = nil) -> [FileItem] {
        var out: [FileItem] = []
        for item in items ?? fileTree {
            if item.isDirectory {
                out.append(contentsOf: flattenNotes(item.children ?? []))
            } else {
                out.append(item)
            }
        }
        return out
    }

    public struct FlatRow: Identifiable {
        public let item: FileItem
        public let depth: Int
        public var id: String { item.id }
    }

    /// Flattens the tree into on-screen row order with each row's nesting
    /// depth, respecting which folders are collapsed. Backs the sidebar's
    /// `LazyVStack` — a plain `VStack` over a *recursive* tree of ~2,000
    /// notes had to materialize every row (and every folder below it) up
    /// front, which is what made opening or closing a window slow to begin
    /// with; a flat list is what SwiftUI can actually virtualize.
    ///
    /// Memoized because the sidebar reads it once per body evaluation — which
    /// means once per keystroke in the search field and once per selection
    /// change — while the walk itself is O(vault). The single cache entry is
    /// enough: a second window with a different set of collapsed folders just
    /// evicts it, costing exactly the walk that would have happened anyway.
    public func visibleFlattenedItems(collapsed: Set<String>) -> [FlatRow] {
        if let cached = flattenedCache, cached.collapsed == collapsed { return cached.rows }
        var out: [FlatRow] = []
        appendFlattened(fileTree, collapsed: collapsed, depth: 0, into: &out)
        flattenedCache = (collapsed, out)
        return out
    }

    private func appendFlattened(_ items: [FileItem], collapsed: Set<String>, depth: Int, into out: inout [FlatRow]) {
        for item in items {
            out.append(FlatRow(item: item, depth: depth))
            if item.isDirectory, !collapsed.contains(item.id), let children = item.children {
                appendFlattened(children, collapsed: collapsed, depth: depth + 1, into: &out)
            }
        }
    }

    /// Just the IDs, in the same order — the range a shift-click selects along.
    public func visibleOrderedIDs(collapsed: Set<String>) -> [String] {
        visibleFlattenedItems(collapsed: collapsed).map(\.item.id)
    }

    public func search(query: String, limit: Int = 60) -> [SearchResult] {
        searchIndex.search(query: query, limit: limit)
    }

    /// Off-main-actor search, for the type-ahead paths.
    public func searchAsync(query: String, limit: Int = 60) async -> [SearchResult] {
        await Self.runSearch(searchIndex, query: query, limit: limit)
    }

    private nonisolated static func runSearch(
        _ index: SearchIndex, query: String, limit: Int
    ) async -> [SearchResult] {
        index.search(query: query, limit: limit)
    }

    /// Depth-first lookup by ID. Deliberately iterative: the recursive form
    /// re-entered `fileTree` whenever it reached a leaf (files carry a nil
    /// `children`), so any miss recursed forever and blew the stack.
    public func findInTree(id: String, in items: [FileItem]? = nil) -> FileItem? {
        let wholeTree = items == nil
        if wholeTree, let lastFound, lastFound.id == id { return lastFound }
        var stack = items ?? fileTree
        while let node = stack.popLast() {
            if node.id == id {
                if wholeTree { lastFound = node }
                return node
            }
            if let children = node.children, !children.isEmpty {
                stack.append(contentsOf: children)
            }
        }
        return nil
    }

    /// Ancestor folder IDs of `url`, for expanding a path down to a revealed item.
    public func ancestorFolderIDs(of url: URL) -> Set<String> {
        guard let vault = activeVault else { return [] }
        let vaultPath = vault.url.standardizedFileURL.path
        var ids: Set<String> = []
        var dir = url.standardizedFileURL.deletingLastPathComponent()
        while dir.path.hasPrefix(vaultPath) && dir.path != vaultPath {
            ids.insert(dir.standardizedFileURL.path)
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return ids
    }

    public func noteContentDidChange(at url: URL, content: String) {
        guard let vault = activeVault else { return }
        indexer.noteChanged(url: url, content: content, vault: vault.url)
        // A save can add or remove wiki links, so the cached graph no longer
        // matches the vault. Only the cache is dropped, never a rebuild kicked
        // off — the graph is rebuilt lazily the next time it's opened, so this
        // costs nothing while you type.
        graphCache[vault.id] = nil
    }

    /// Where a new note/folder should land: inside `near` if it's a folder,
    /// alongside it otherwise, or the vault root with nothing selected.
    public func parentDirectory(near item: FileItem?) -> URL? {
        guard let active = activeVault else { return nil }
        guard let item else { return active.url }
        if item.isDirectory {
            return item.url
        }
        return item.url.deletingLastPathComponent()
    }

    @discardableResult
    public func createNote(named rawName: String = "Untitled", in directory: URL? = nil, near: FileItem? = nil) -> FileItem? {
        guard let active = activeVault else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Untitled" : trimmed

        let sanitized = baseName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let stem = sanitized.lowercased().hasSuffix(".md")
            ? String(sanitized.dropLast(3))
            : sanitized
        let parent = directory ?? parentDirectory(near: near) ?? active.url
        let fileURL = uniqueURL(in: parent, stem: stem, ext: "md")

        let heading = fileURL.deletingPathExtension().lastPathComponent
        try? "# \(heading)\n\n".write(to: fileURL, atomically: true, encoding: .utf8)
        invalidateGraphCache()
        refreshFileTree()
        let item = FileItem(url: fileURL, isDirectory: false)
        indexer.noteAdded(url: fileURL, vault: active.url)
        return item
    }

    @discardableResult
    public func createFolder(named rawName: String = "New Folder", in directory: URL? = nil, near: FileItem? = nil) -> FileItem? {
        guard let active = activeVault else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "New Folder" : trimmed
        let sanitized = baseName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let parent = directory ?? parentDirectory(near: near) ?? active.url
        let folderURL = uniqueDirectoryURL(in: parent, stem: sanitized)

        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        refreshFileTree()
        return FileItem(url: folderURL, isDirectory: true, children: [])
    }

    /// Renames `item` in place. Returns the item at its new location.
    @discardableResult
    public func commitRename(_ item: FileItem, to newTitle: String, focusEditor: Bool) -> FileItem {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (trimmed.isEmpty ? item.displayTitle : trimmed)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        let parent = item.url.deletingLastPathComponent()
        var dest: URL

        if item.isDirectory {
            dest = parent.appendingPathComponent(title)
            if dest.standardizedFileURL.path != item.url.standardizedFileURL.path {
                dest = uniqueDirectoryURL(in: parent, stem: title, skipping: item.url)
                do {
                    try FileManager.default.moveItem(at: item.url, to: dest)
                } catch {
                    NSLog("BlackGlass rename failed: \(error.localizedDescription)")
                    dest = item.url
                }
            }
        } else {
            let ext = item.url.pathExtension.isEmpty ? "md" : item.url.pathExtension
            dest = parent.appendingPathComponent("\(title).\(ext)")
            if dest.standardizedFileURL.path != item.url.standardizedFileURL.path {
                dest = uniqueURL(in: parent, stem: title, ext: ext, skipping: item.url)
                do {
                    try FileManager.default.moveItem(at: item.url, to: dest)
                } catch {
                    NSLog("BlackGlass rename failed: \(error.localizedDescription)")
                    dest = item.url
                }
            }

            updateHeading(at: dest, from: item.displayTitle, to: dest.deletingPathExtension().lastPathComponent)
            if let vault = activeVault {
                if dest.standardizedFileURL.path != item.url.standardizedFileURL.path {
                    indexer.noteMoved(from: item.url, to: dest, vault: vault.url)
                } else {
                    indexer.noteAdded(url: dest, vault: vault.url)
                }
            }
        }

        // Only when the item actually moved. `dest` still equals `item.url`
        // when the typed name matched the existing one — Enter on an unedited
        // field, which is how a freshly created note's pre-filled name gets
        // accepted — or when the move failed; either way the vault on disk is
        // untouched (`updateHeading` sees an unchanged title and returns), so
        // the tree has nothing new to show and the graph's link set can't have
        // changed. This was costing a full recursive walk of the vault and a
        // forced graph rebuild for a rename that renamed nothing.
        if dest.standardizedFileURL.path != item.url.standardizedFileURL.path {
            invalidateGraphCache()
            refreshFileTree()
        }
        if focusEditor && !item.isDirectory {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .blackGlassFocusEditor, object: nil)
            }
        }
        return FileItem(url: dest, isDirectory: item.isDirectory)
    }

    /// Moves each item into `destinationFolder`, Finder-style. Refuses
    /// no-ops and dropping a folder into itself or its own descendant.
    /// Returns an old-ID → new-ID map so callers can carry a selection across.
    @discardableResult
    public func moveItems(_ items: [FileItem], to destinationFolder: URL) -> [String: String] {
        guard let active = activeVault else { return [:] }
        let destFolder = destinationFolder.standardizedFileURL
        var remap: [String: String] = [:]

        for item in items {
            let source = item.url.standardizedFileURL
            guard source.path != destFolder.path,
                  !destFolder.path.hasPrefix(source.path + "/"),
                  source.deletingLastPathComponent().standardizedFileURL.path != destFolder.path else { continue }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                let subtree = findInTree(id: source.path)
                let movedNotes = subtree.map { flattenNotes([$0]) } ?? []
                let relativePaths = movedNotes.map { String($0.url.standardizedFileURL.path.dropFirst(source.path.count)) }
                let dest = uniqueDirectoryURL(in: destFolder, stem: source.lastPathComponent)
                do {
                    try FileManager.default.moveItem(at: source, to: dest)
                } catch {
                    NSLog("BlackGlass move failed: \(error.localizedDescription)")
                    continue
                }
                for (note, relative) in zip(movedNotes, relativePaths) {
                    indexer.noteMoved(from: note.url, to: dest.appendingPathComponent(relative), vault: active.url)
                }
                // Every descendant's path changed too, not just the folder's.
                // Without these entries a selection inside the moved folder
                // keeps dead IDs — rows stop highlighting and ⌫ no-ops.
                let destPath = dest.standardizedFileURL.path
                remap[source.path] = destPath
                for oldPath in (subtree?.folderIDsInSubtree ?? []).union(movedNotes.map(\.id)) {
                    guard oldPath != source.path,
                          oldPath.hasPrefix(source.path + "/") else { continue }
                    remap[oldPath] = destPath + oldPath.dropFirst(source.path.count)
                }
            } else {
                let stem = source.deletingPathExtension().lastPathComponent
                let dest = uniqueURL(in: destFolder, stem: stem, ext: source.pathExtension)
                do {
                    try FileManager.default.moveItem(at: source, to: dest)
                } catch {
                    NSLog("BlackGlass move failed: \(error.localizedDescription)")
                    continue
                }
                indexer.noteMoved(from: source, to: dest, vault: active.url)
                remap[source.path] = dest.standardizedFileURL.path
            }
        }
        invalidateGraphCache()
        refreshFileTree()
        return remap
    }

    /// Moves `items` into `destinationFolder` and parks them immediately
    /// before `beforeName` (or at the end, when nil), recording the result as
    /// that folder's manual order.
    ///
    /// Items already in the destination aren't moved on disk at all — a
    /// same-folder drag is purely a reorder, and `moveItems` rightly refuses
    /// it as a no-op — but they still take their new position.
    @discardableResult
    public func reorderItems(_ items: [FileItem], into destinationFolder: URL, before beforeName: String?) -> [String: String] {
        let destFolder = destinationFolder.standardizedFileURL
        let incoming = items.filter {
            $0.url.deletingLastPathComponent().standardizedFileURL.path != destFolder.path
        }
        let remap = incoming.isEmpty ? [:] : moveItems(incoming, to: destFolder)

        // A plain drop *into* a folder shouldn't silently freeze that folder
        // into manual order for good — it only earns an order once something
        // is deliberately positioned in it, or if it already had one.
        //
        // No refresh here: `moveItems` already did one if anything actually
        // moved, and if nothing did there is nothing to redraw. This was a
        // second full recursive walk of the whole vault per drag.
        guard beforeName != nil || treeOrder.currentOrder(in: destFolder) != nil else {
            return remap
        }

        // Names as they actually landed — a collision may have renamed one.
        let movedNames = items.map { item in
            URL(fileURLWithPath: remap[item.id] ?? item.id).lastPathComponent
        }
        var ordered = childNames(of: destFolder).filter { !movedNames.contains($0) }
        let insertAt = beforeName.flatMap { name in
            movedNames.contains(name) ? nil : ordered.firstIndex(of: name)
        } ?? ordered.count
        ordered.insert(contentsOf: movedNames, at: insertAt)

        treeOrder.setOrder(ordered, in: destFolder)
        refreshFileTree()
        return remap
    }

    /// Restores a folder to plain name order.
    public func clearManualOrder(of folder: URL) {
        treeOrder.clearOrder(in: folder)
        refreshFileTree()
    }

    public func hasManualOrder(_ folder: URL) -> Bool {
        treeOrder.currentOrder(in: folder) != nil
    }

    /// Everything in `folder` the sidebar would show, in current tree order.
    private func childNames(of folder: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return treeOrder.sorted(contents, in: folder).compactMap { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            if isDir.boolValue { return url.lastPathComponent }
            return Self.importableExtensions.contains(url.pathExtension.lowercased()) ? url.lastPathComponent : nil
        }
    }

    /// File types the vault will take in. The sidebar only ever represents
    /// note files, so anything else has nowhere to live.
    public static let importableExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Copies external files — dragged in from Finder — into
    /// `destinationFolder`. Dropped folders are imported recursively,
    /// keeping their structure. Sources that already live in this vault are
    /// *moved* rather than duplicated: dragging a note in from a Finder
    /// window showing the vault should behave like dragging it in the tree,
    /// not leave a "note 2" behind.
    public func importFiles(_ urls: [URL], into destinationFolder: URL) {
        guard let active = activeVault else { return }
        let destFolder = destinationFolder.standardizedFileURL
        let vaultPath = active.url.standardizedFileURL.path

        let inVault = urls.filter { $0.standardizedFileURL.path.hasPrefix(vaultPath + "/") }
        let external = urls.filter { !$0.standardizedFileURL.path.hasPrefix(vaultPath + "/") }

        if !inVault.isEmpty {
            moveItems(inVault.compactMap { findInTree(id: $0.standardizedFileURL.path) }, to: destFolder)
        }

        var imported = 0
        var skipped = 0

        for source in external {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let dest = uniqueDirectoryURL(in: destFolder, stem: source.lastPathComponent)
                let counts = importDirectory(source, into: dest, vault: active.url)
                imported += counts.imported
                skipped += counts.skipped
            } else if importFile(source, into: destFolder, vault: active.url) {
                imported += 1
            } else {
                skipped += 1
            }
        }

        lastImportSummary = Self.importSummary(imported: imported, skipped: skipped)
        guard imported > 0 else { return }
        invalidateGraphCache()
        refreshFileTree()
    }

    /// One file handed over by a browser drop: its bytes plus the path it
    /// had relative to whatever was dropped, so a dropped folder keeps its
    /// shape on the way in.
    public struct Upload: Sendable {
        public let relativePath: String
        public let data: Data

        public init(relativePath: String, data: Data) {
            self.relativePath = relativePath
            self.data = data
        }
    }

    /// Web counterpart to `importFiles`. A browser can't hand over URLs the
    /// app could go and read for itself, so a drop onto the web client
    /// arrives as bytes and has to be written rather than copied. Returns
    /// the files that actually landed.
    @discardableResult
    public func importUploads(_ uploads: [Upload], into destinationFolder: URL) -> [URL] {
        guard let active = activeVault else { return [] }
        let destFolder = destinationFolder.standardizedFileURL
        var landed: [URL] = []
        var skipped = 0
        // A dropped folder arrives as one upload per file inside it, so the
        // name each directory resolves to has to be decided once and reused.
        // Picking a fresh unique name per file would scatter one dropped
        // folder across "Notes", "Notes 2", "Notes 3"...
        var folders: [String: URL] = [:]

        for upload in uploads {
            let parts = upload.relativePath
                .split(separator: "/")
                .map(String.init)
                .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            guard let name = parts.last else { continue }
            guard Self.importableExtensions.contains((name as NSString).pathExtension.lowercased()) else {
                skipped += 1
                continue
            }

            var parent = destFolder
            for (depth, component) in parts.dropLast().enumerated() {
                let key = parts[0...depth].joined(separator: "/")
                if let known = folders[key] {
                    parent = known
                    continue
                }
                // Only the outermost component competes for a unique name.
                // Everything below it lives inside a folder that is already
                // new, so it keeps the name it was dropped with.
                let child = depth == 0
                    ? uniqueDirectoryURL(in: parent, stem: component)
                    : parent.appendingPathComponent(component)
                folders[key] = child
                parent = child
            }

            guard (try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)) != nil else {
                skipped += 1
                continue
            }
            let dest = uniqueURL(
                in: parent,
                stem: (name as NSString).deletingPathExtension,
                ext: (name as NSString).pathExtension
            )
            do {
                try upload.data.write(to: dest, options: .atomic)
            } catch {
                NSLog("BlackGlass upload failed: \(error.localizedDescription)")
                skipped += 1
                continue
            }
            indexer.noteAdded(url: dest, vault: active.url)
            landed.append(dest)
        }

        lastImportSummary = Self.importSummary(imported: landed.count, skipped: skipped)
        guard !landed.isEmpty else { return [] }
        invalidateGraphCache()
        refreshFileTree()
        return landed
    }

    /// Copies one file in, if its type is importable. Returns whether it landed.
    private func importFile(_ source: URL, into destFolder: URL, vault: URL) -> Bool {
        guard Self.importableExtensions.contains(source.pathExtension.lowercased()) else { return false }
        let stem = source.deletingPathExtension().lastPathComponent
        let dest = uniqueURL(in: destFolder, stem: stem, ext: source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            NSLog("BlackGlass import failed: \(error.localizedDescription)")
            return false
        }
        indexer.noteAdded(url: dest, vault: vault)
        return true
    }

    /// Walks a dropped folder, recreating it under `dest` with only the
    /// importable files in it. Directories that end up contributing nothing
    /// are removed again rather than left as empty shells.
    private func importDirectory(_ source: URL, into dest: URL, vault: URL) -> (imported: Int, skipped: Int) {
        var imported = 0
        var skipped = 0
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        guard (try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)) != nil else {
            return (0, contents.count)
        }

        for child in contents {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let counts = importDirectory(child, into: dest.appendingPathComponent(child.lastPathComponent), vault: vault)
                imported += counts.imported
                skipped += counts.skipped
            } else if importFile(child, into: dest, vault: vault) {
                imported += 1
            } else {
                skipped += 1
            }
        }

        if imported == 0 {
            try? FileManager.default.removeItem(at: dest)
        }
        return (imported, skipped)
    }

    private static func importSummary(imported: Int, skipped: Int) -> String? {
        switch (imported, skipped) {
        case (0, 0): return nil
        case (0, let s): return "Nothing imported — \(s) unsupported file\(s == 1 ? "" : "s")"
        case (let i, 0): return "Imported \(i) file\(i == 1 ? "" : "s")"
        case (let i, let s): return "Imported \(i) file\(i == 1 ? "" : "s"), skipped \(s) unsupported"
        }
    }

    private func uniqueURL(in parent: URL, stem: String, ext: String, skipping: URL? = nil) -> URL {
        var url = parent.appendingPathComponent("\(stem).\(ext)")
        if url.standardizedFileURL.path == skipping?.standardizedFileURL.path {
            return url
        }
        var index = 2
        while FileManager.default.fileExists(atPath: url.path)
                && url.standardizedFileURL.path != skipping?.standardizedFileURL.path {
            url = parent.appendingPathComponent("\(stem) \(index).\(ext)")
            index += 1
        }
        return url
    }

    private func uniqueDirectoryURL(in parent: URL, stem: String, skipping: URL? = nil) -> URL {
        var url = parent.appendingPathComponent(stem)
        if url.standardizedFileURL.path == skipping?.standardizedFileURL.path {
            return url
        }
        var index = 2
        while FileManager.default.fileExists(atPath: url.path)
                && url.standardizedFileURL.path != skipping?.standardizedFileURL.path {
            url = parent.appendingPathComponent("\(stem) \(index)")
            index += 1
        }
        return url
    }

    private func updateHeading(at url: URL, from oldTitle: String, to newTitle: String) {
        guard oldTitle != newTitle,
              var content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let oldPrefix = "# \(oldTitle)"
        guard content.hasPrefix(oldPrefix) else { return }
        if let newline = content.firstIndex(of: "\n") {
            content = "# \(newTitle)" + content[newline...]
        } else {
            content = "# \(newTitle)\n\n"
        }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Notes a folder deletion would take down with it — the count the
    /// >10-item confirmation threshold is measured against.
    public func affectedNoteCount(of items: [FileItem]) -> Int {
        items.reduce(0) { $0 + ($1.isDirectory ? max(1, flattenNotes([$1]).count) : 1) }
    }

    /// Trashes every item and records them for `undoLastDelete()`. A later
    /// call replaces the previous batch — only the most recent delete undoes.
    public func deleteItems(_ items: [FileItem]) {
        var entries: [DeletedBatch.Entry] = []
        var affected = 0
        for item in items {
            if item.isDirectory {
                let notes = flattenNotes([item])
                for note in notes { indexer.noteRemoved(url: note.url) }
                affected += max(1, notes.count)
            } else {
                indexer.noteRemoved(url: item.url)
                affected += 1
            }
            var trashedURL: NSURL?
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashedURL)
            } catch {
                NSLog("BlackGlass delete failed: \(error.localizedDescription)")
                continue
            }
            guard let trashed = trashedURL as URL? else { continue }
            entries.append(DeletedBatch.Entry(original: item.url, trashed: trashed, isDirectory: item.isDirectory))
        }
        lastDelete = entries.isEmpty ? nil : DeletedBatch(entries: entries, affectedCount: affected)
        invalidateGraphCache()
        refreshFileTree()
    }

    /// Restores the last trashed batch to its original location(s).
    public func undoLastDelete() {
        guard let batch = lastDelete, let active = activeVault else { return }
        for entry in batch.entries {
            do {
                try FileManager.default.moveItem(at: entry.trashed, to: entry.original)
            } catch {
                NSLog("BlackGlass undo failed: \(error.localizedDescription)")
                continue
            }
            if entry.isDirectory {
                let restored = FileItem(url: entry.original, isDirectory: true)
                for note in flattenNotes([restored]) {
                    indexer.noteAdded(url: note.url, vault: active.url)
                }
            } else {
                indexer.noteAdded(url: entry.original, vault: active.url)
            }
        }
        lastDelete = nil
        invalidateGraphCache()
        refreshFileTree()
    }

    private func loadDirectory(at url: URL) -> [FileItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [FileItem] = []
        for fileURL in treeOrder.sorted(contents, in: url) {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let isDir = resourceValues?.isDirectory ?? false
            let modDate = resourceValues?.contentModificationDate

            if isDir {
                let subItems = loadDirectory(at: fileURL)
                items.append(FileItem(url: fileURL, isDirectory: true, children: subItems, modifiedAt: modDate))
            } else if Self.importableExtensions.contains(fileURL.pathExtension.lowercased()) {
                // The shared set rather than an array literal: this is the
                // inner loop of a full-vault walk, and the literal was
                // allocating a three-element array once per file in the vault.
                items.append(FileItem(url: fileURL, isDirectory: false, modifiedAt: modDate))
            }
        }
        return items
    }

    private func ensureDefaultVaultIfNeeded() {
        if vaults.isEmpty {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let defaultVaultPath = docs.appendingPathComponent("BlackGlass Vault", isDirectory: true)
            try? FileManager.default.createDirectory(at: defaultVaultPath, withIntermediateDirectories: true)

            let sampleNote = defaultVaultPath.appendingPathComponent("Welcome to BlackGlass.md")
            if !FileManager.default.fileExists(atPath: sampleNote.path) {
                let sampleContent = """
                # Welcome to BlackGlass 💧

                A lightweight, 2-pane notebook with a Liquid Glass visual aesthetic.

                ### Features

                - **Two-Pane Workspace**: Narrow left pane navigation, distraction-free live editor on the right.
                - **Multi-Vault Architecture**: Set up multiple directories and switch on the fly.
                - **Uncooked vs. Cooked**: The little egg glyph switches raw markdown (whole egg) and rendered view (sunny side up).
                - **Omnibar (⌘K)**: Instant full-text search across all notes in your active vault.

                ### Shortcuts

                | Action | Keys |
                | --- | --- |
                | Search notes | ⌘K |
                | New note | ⌘N |
                | Toggle uncooked / cooked | ⌘E |
                | Manage vaults | ⇧⌘O |

                Enjoy fast, native note-taking.
                """
                try? sampleContent.write(to: sampleNote, atomically: true, encoding: .utf8)
            }

            addVault(name: "Default Notebook", path: defaultVaultPath.path)
        }
    }
}
