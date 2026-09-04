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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("LiquidNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("tree-order.json")
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
        let byName = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        guard let placed = order[folder.standardizedFileURL.path], !placed.isEmpty else { return byName }

        let rank = Dictionary(uniqueKeysWithValues: placed.enumerated().map { ($1, $0) })
        return byName.sorted { a, b in
            switch (rank[a.lastPathComponent], rank[b.lastPathComponent]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        }
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
