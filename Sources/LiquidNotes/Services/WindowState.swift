import Foundation
import SwiftUI

/// Per-window navigation/selection UI state. Owned once per window (as a
/// `@StateObject` on that window's root view) so windows never mirror each
/// other's selection, expanded folders, or pane (graph vs. editor vs.
/// search) — only the underlying vault data in `VaultManager` is shared.
@MainActor
final class WindowState: ObservableObject {
    /// IDs (standardized paths) of the selected rows, Finder-style multi-select.
    @Published var selection: Set<String> = []
    /// Last item clicked without a modifier — the fixed end a shift-click range extends from.
    @Published var anchorID: String?
    @Published var renamingID: String?
    /// Folder IDs the user collapsed. Missing IDs are expanded.
    @Published var collapsedFolderIDs: Set<String> = []
    @Published var pendingReveal: VaultManager.TreeReveal?
    @Published var sidebarVisible = true
    @Published var showGraph = false
    @Published var searchQuery = ""
    @Published var isSearching = false
    @Published var showOmnibar = false
    /// Published rather than kept inside `OmnibarView` so the graph can dim
    /// non-matches while an Omnisearch is being typed.
    @Published var omnibarQuery = ""
    /// IDs currently being dragged out of the tree, published the moment the
    /// drag starts. `DropDelegate.validateDrop` has to answer synchronously,
    /// but a drop payload can only be read asynchronously — so legality
    /// (self-drop, descendant-drop, same-parent no-op) is decided against
    /// this instead. Empty means the drag came from outside the app.
    @Published var draggingIDs: [String] = []
    /// Folder a drag is currently hovering, so the row that will actually
    /// receive the drop highlights — including when the cursor is over one of
    /// that folder's *files*, since those land in the folder alongside them.
    @Published var dropTargetFolderID: String?
    /// Where an insertion line is currently drawn — the row it sits against,
    /// and which edge. Set instead of `dropTargetFolderID` when the cursor is
    /// near a row's edge rather than its middle, so "put it between these
    /// two" and "put it inside this folder" look different.
    @Published var dropInsertion: DropInsertion?

    struct DropInsertion: Equatable {
        let rowID: String
        let below: Bool
    }
    @Published var showManageVaults = false
    @Published var showSettings = false

    /// The single selected item, when exactly one row is selected.
    var soleSelectedID: String? {
        selection.count == 1 ? selection.first : nil
    }

    func select(_ item: FileItem) {
        selection = [item.id]
        anchorID = item.id
    }

    func toggle(_ item: FileItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
        anchorID = item.id
    }

    /// Extends the selection from `anchorID` to `item` along `visibleOrder`
    /// (the flattened, on-screen row order), replacing the prior selection —
    /// same as Finder's shift-click.
    func extendSelection(to item: FileItem, visibleOrder: [String]) {
        guard let anchor = anchorID, let anchorIndex = visibleOrder.firstIndex(of: anchor),
              let targetIndex = visibleOrder.firstIndex(of: item.id) else {
            select(item)
            return
        }
        let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        selection = Set(visibleOrder[range])
    }

    func toggleFolder(_ item: FileItem) {
        if collapsedFolderIDs.contains(item.id) {
            collapsedFolderIDs.remove(item.id)
        } else {
            collapsedFolderIDs.insert(item.id)
        }
    }

    /// Selects `item`, expands its ancestor folders, and asks the sidebar to
    /// scroll it into view.
    func reveal(_ item: FileItem, ancestorFolderIDs: Set<String>) {
        selection = [item.id]
        anchorID = item.id
        collapsedFolderIDs.subtract(ancestorFolderIDs)
        pendingReveal = VaultManager.TreeReveal(itemID: item.id, nonce: UUID())
    }

    /// Drops any selected/renaming/revealed IDs that no longer exist — call
    /// after a delete or move changes which paths are live.
    func discard(ids: Set<String>) {
        selection.subtract(ids)
        if let anchorID, ids.contains(anchorID) { self.anchorID = nil }
        if let renamingID, ids.contains(renamingID) { self.renamingID = nil }
    }

    /// Remaps IDs after a move/rename changes their paths, keeping the same
    /// logical items selected under their new IDs.
    func remap(_ mapping: [String: String]) {
        selection = Set(selection.map { mapping[$0] ?? $0 })
        if let anchorID { self.anchorID = mapping[anchorID] ?? anchorID }
    }

    /// Resolves the current single-selection to a live `FileItem`, for
    /// "create near the selection" placement.
    private func soleSelected(in vaultManager: VaultManager) -> FileItem? {
        soleSelectedID.flatMap { vaultManager.findInTree(id: $0) }
    }

    func requestNewNote(in vaultManager: VaultManager) {
        guard let item = vaultManager.createNote(near: soleSelected(in: vaultManager)) else { return }
        select(item)
        renamingID = item.id
    }

    func requestNewFolder(in vaultManager: VaultManager) {
        guard let item = vaultManager.createFolder(near: soleSelected(in: vaultManager)) else { return }
        select(item)
        renamingID = item.id
    }

    /// Ends an in-progress rename without committing it.
    func cancelRename() {
        renamingID = nil
    }

    /// Selects `item`, expands its ancestors, and scrolls it into view — for
    /// jumping to a note from search, a wiki-link click, or the graph.
    func revealInTree(_ item: FileItem, in vaultManager: VaultManager) {
        reveal(item, ancestorFolderIDs: vaultManager.ancestorFolderIDs(of: item.url))
    }
}

/// Publishes the key window's `WindowState` up to the App's `.commands`, so
/// menu items with a per-window effect (New Note, New Folder, search) act on
/// whichever window is actually frontmost instead of every open window at once.
private struct FocusedWindowStateKey: FocusedValueKey {
    typealias Value = WindowState
}

extension FocusedValues {
    var windowState: WindowState? {
        get { self[FocusedWindowStateKey.self] }
        set { self[FocusedWindowStateKey.self] = newValue }
    }
}
