import Foundation

/// Manual sidebar ordering, per folder.
///
/// The tree is otherwise name-sorted, which is fine until you want a
/// particular note pinned to the top of its folder. Stored outside the vault
/// (in Application Support, keyed by absolute folder path) so dragging notes
/// around never writes stray sidecar files into someone's notes.
///
/// Only the folders the user has actually reordered appear here; everything
/// else keeps sorting by name, and a folder whose entry goes stale — it was
/// renamed or moved — simply falls back to name order rather than erroring.
@MainActor
final class TreeOrderStore {
    /// Absolute folder path → the child names in the order the user put them.
    /// Names, not paths, so renaming the parent doesn't orphan the children.
    private var order: [String: [String]] = [:]
    private let url: URL

    init() {
        url = AppSupport.folder.appendingPathComponent("tree-order.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            order = decoded
        }
    }

    /// Sorts one folder's children. Anything the user has explicitly placed
    /// comes first in their order; everything else follows, name-sorted, so a
    /// note added on disk since the last reorder still shows up predictably
    /// instead of vanishing or jumping to the top.
    func sorted(_ urls: [URL], in folder: URL) -> [URL] {
        // Names are pulled out once and carried alongside their URLs. Asking
        // each URL for `lastPathComponent` from inside the comparator
        // recomputed it O(n log n) times, allocating a fresh path string for
        // every comparison — on a real vault that was most of the cost of
        // loading the tree, and the tree is reloaded after every edit.
        var named = urls.map { ($0.lastPathComponent, $0) }
        named.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        guard let placed = order[folder.standardizedFileURL.path], !placed.isEmpty else {
            return named.map { $0.1 }
        }

        let rank = Dictionary(uniqueKeysWithValues: placed.enumerated().map { ($1, $0) })
        named.sort { a, b in
            switch (rank[a.0], rank[b.0]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                return a.0.localizedStandardCompare(b.0) == .orderedAscending
            }
        }
        return named.map { $0.1 }
    }

    /// Records `names` as the full order of `folder`'s children.
    func setOrder(_ names: [String], in folder: URL) {
        order[folder.standardizedFileURL.path] = names
        save()
    }

    func currentOrder(in folder: URL) -> [String]? {
        order[folder.standardizedFileURL.path]
    }

    /// Drops a folder's ordering — it went back to being name-sorted, or the
    /// folder is gone.
    func clearOrder(in folder: URL) {
        guard order.removeValue(forKey: folder.standardizedFileURL.path) != nil else { return }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(order) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
