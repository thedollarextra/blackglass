import Foundation

/// What link resolution and the `tag:` query actually need. Outgoing links,
/// headings, block ids and css classes used to be retained here for a graph
/// path that no longer exists; the graph builds its own edge table now.
struct NoteRecord: Sendable {
    var url: URL
    var title: String
    var relativePath: String
    var aliases: [String]
    var tags: [String]
}

struct GraphNodeInfo: Identifiable, Sendable {
    var id: String { path }
    var title: String
    var path: String
    var unresolved: Bool
}

struct GraphEdgeInfo: Hashable, Sendable {
    var from: String
    var to: String
}

final class WikiIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String: NoteRecord] = [:]
    private var byTitle: [String: [String]] = [:]
    private var byAlias: [String: String] = [:]
    private var filesByName: [String: [String]] = [:]
    private var vaultURL: URL?

    func clear() {
        lock.lock()
        notes.removeAll()
        byTitle.removeAll()
        byAlias.removeAll()
        filesByName.removeAll()
        vaultURL = nil
        lock.unlock()
    }

    /// Swap in a finished index. The walking, reading and parsing happen in
    /// `IndexCoordinator` so a single pass over the vault feeds both indexes.
    func install(records: [NoteRecord], fileNames: [String: [String]], vault: URL) {
        var nextNotes: [String: NoteRecord] = [:]
        var nextTitle: [String: [String]] = [:]
        var nextAlias: [String: String] = [:]
        nextNotes.reserveCapacity(records.count)
        for rec in records {
            let key = rec.url.path
            nextNotes[key] = rec
            let lowerTitle = rec.title.lowercased()
            nextTitle[lowerTitle, default: []].append(key)
            let stem = rec.url.deletingPathExtension().lastPathComponent.lowercased()
            if stem != lowerTitle { nextTitle[stem, default: []].append(key) }
            for alias in rec.aliases { nextAlias[alias.lowercased()] = key }
        }
        lock.lock()
        notes = nextNotes
        byTitle = nextTitle
        byAlias = nextAlias
        filesByName = fileNames
        self.vaultURL = vault
        lock.unlock()
    }

    func upsert(url: URL, content: String, vault: URL) {
        let rec = Self.makeRecord(url: url, vault: vault, content: content)
        let key = rec.url.path
        lock.lock()
        if let old = notes[key] {
            byTitle[old.title.lowercased()]?.removeAll { $0 == key }
            for a in old.aliases { if byAlias[a.lowercased()] == key { byAlias.removeValue(forKey: a.lowercased()) } }
        }
        notes[key] = rec
        byTitle[rec.title.lowercased(), default: []].append(key)
        for alias in rec.aliases { byAlias[alias.lowercased()] = key }
        let name = url.lastPathComponent.lowercased()
        let path = NotePath.key(url)
        if filesByName[name]?.contains(path) != true {
            filesByName[name, default: []].append(path)
        }
        vaultURL = vault
        lock.unlock()
    }

    func remove(url: URL) {
        let key = NotePath.key(url)
        lock.lock()
        if let old = notes.removeValue(forKey: key) {
            byTitle[old.title.lowercased()]?.removeAll { $0 == key }
            for a in old.aliases { if byAlias[a.lowercased()] == key { byAlias.removeValue(forKey: a.lowercased()) } }
        }
        // The filename index too, or a moved note keeps resolving to where
        // it used to be: a move is remove-then-add, so without this the name
        // maps to both paths, and `resolveFile` prefers the shortest — the
        // dead one, whenever a note moves deeper into the tree.
        let name = url.lastPathComponent.lowercased()
        if var paths = filesByName[name] {
            paths.removeAll { $0 == key }
            if paths.isEmpty {
                filesByName.removeValue(forKey: name)
            } else {
                filesByName[name] = paths
            }
        }
        lock.unlock()
    }

    func record(for url: URL) -> NoteRecord? {
        lock.lock(); defer { lock.unlock() }
        return notes[NotePath.key(url)]
    }

    func resolveNote(target dest: String, from current: URL, vault: URL) -> URL? {
        let cleaned = dest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleaned.isEmpty { return current }
        let withExt: [String] = {
            let ext = (cleaned as NSString).pathExtension.lowercased()
            if ["md", "markdown", "txt"].contains(ext) { return [cleaned] }
            return [cleaned + ".md", cleaned + ".markdown", cleaned + ".txt", cleaned]
        }()

        let folder = current.deletingLastPathComponent()
        for name in withExt {
            let same = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: same.path) { return same.standardizedFileURL }
        }
        for name in withExt {
            let root = vault.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: root.path) { return root.standardizedFileURL }
        }

        let stem = (cleaned as NSString).deletingPathExtension
        let key = stem.lowercased()
        lock.lock()
        let titleHits = byTitle[key] ?? []
        let aliasHit = byAlias[key]
        let snapshot = notes
        lock.unlock()

        if let aliasHit, let rec = snapshot[aliasHit] { return rec.url }
        let unique = Set(titleHits)
        if unique.count == 1, let path = unique.first, let rec = snapshot[path] { return rec.url }
        if unique.count > 1 {
            let ranked = unique.compactMap { snapshot[$0] }.sorted {
                relative($0.url, vault: vault).count < relative($1.url, vault: vault).count
            }
            return ranked.first?.url
        }
        return nil
    }

    func resolveFile(named dest: String, from current: URL, vault: URL) -> URL? {
        let cleaned = dest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleaned.isEmpty { return nil }
        let folder = current.deletingLastPathComponent()
        let same = folder.appendingPathComponent(cleaned)
        if FileManager.default.fileExists(atPath: same.path) { return same.standardizedFileURL }
        let root = vault.appendingPathComponent(cleaned)
        if FileManager.default.fileExists(atPath: root.path) { return root.standardizedFileURL }
        let name = URL(fileURLWithPath: cleaned).lastPathComponent.lowercased()
        lock.lock()
        let hits = filesByName[name] ?? []
        lock.unlock()
        if hits.count == 1 { return URL(fileURLWithPath: hits[0]) }
        if let closest = hits.min(by: { $0.count < $1.count }) {
            return URL(fileURLWithPath: closest)
        }
        return nil
    }

    func notesWithTag(_ tag: String) -> [NoteRecord] {
        let needle = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        lock.lock(); defer { lock.unlock() }
        return notes.values.filter { rec in
            rec.tags.contains { $0.caseInsensitiveCompare(needle) == .orderedSame || $0.lowercased().hasPrefix(needle.lowercased() + "/") }
        }
    }

    func relative(_ url: URL, vault: URL) -> String { Self.relativePath(url, vault: vault) }

    static func relativePath(_ url: URL, vault: URL) -> String {
        let full = url.standardizedFileURL.path
        let root = vault.standardizedFileURL.path
        if full.hasPrefix(root) {
            return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    /// Rough resident cost of the record tables, in bytes.
    var approximateBytes: Int {
        lock.lock(); defer { lock.unlock() }
        var total = 0
        for (path, rec) in notes {
            total += path.utf8.count + rec.title.utf8.count + rec.relativePath.utf8.count + 96
            for a in rec.aliases { total += a.utf8.count + 16 }
            for t in rec.tags { total += t.utf8.count + 16 }
        }
        for (name, paths) in filesByName {
            total += name.utf8.count + 16
            for p in paths { total += p.utf8.count + 16 }
        }
        return total
    }

    var noteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return notes.count
    }

    static func makeRecord(url: URL, vault: URL, content: String) -> NoteRecord {
        let fm = OFMParser.extractFrontmatter(content)
        return NoteRecord(
            url: URL(fileURLWithPath: NotePath.key(url)),
            title: FileItem(url: url, isDirectory: false).displayTitle,
            relativePath: relativePath(url, vault: vault),
            aliases: fm.aliases,
            tags: fm.tags
        )
    }
}
