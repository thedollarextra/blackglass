import Foundation

public struct FileItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let isDirectory: Bool
    public var children: [FileItem]?
    public var modifiedAt: Date?

    public init(url: URL, isDirectory: Bool, children: [FileItem]? = nil, modifiedAt: Date? = nil) {
        // Standardized once, not twice: this runs for every file in the vault
        // on each tree load, and collapsing `/private` can hit the filesystem.
        // `name` stays on the original URL so it keeps its exact old meaning.
        let standardized = url.standardizedFileURL
        self.id = standardized.path
        self.name = url.lastPathComponent
        self.url = standardized
        self.isDirectory = isDirectory
        self.children = children
        self.modifiedAt = modifiedAt
    }

    /// Strips `.md` or `.txt` extensions for a cleaner notebook look in the tree
    public var displayTitle: String {
        if isDirectory { return name }
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" || ext == "txt" {
            return url.deletingPathExtension().lastPathComponent
        }
        return name
    }

    /// This item's own ID plus every descendant folder's ID, if it's a
    /// folder — the sidebar's "Expand All"/"Collapse All". `children` is
    /// already the full loaded subtree, so no vault access is needed here.
    public var folderIDsInSubtree: Set<String> {
        guard isDirectory else { return [] }
        var out: Set<String> = [id]
        for child in children ?? [] {
            out.formUnion(child.folderIDsInSubtree)
        }
        return out
    }
}
