import Foundation

/// Canonical on-disk identity for a note.
///
/// `standardizedFileURL` collapses a leading `/private` only while the file
/// still exists, so a note that was just deleted or renamed hashes differently
/// from the entry the index stored for it, and the entry is never evicted.
/// Every `/private` subdirectory on macOS has a root symlink, so stripping the
/// prefix unconditionally still names an openable file.
public enum NotePath {
    public static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}

/// Shared note reader. `String(contentsOf:encoding:)` runs encoding detection
/// on every call and gives up entirely on a single bad byte; decoding the bytes
/// directly is faster and keeps notes with stray bytes in the index.
public enum FileText {
    public static func read(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct SearchResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let fileItem: FileItem
    public let title: String
    public let snippet: String
    public let lineMatch: String?
}

/// One note reduced to what the index actually keeps. Built off the main thread
/// during a rebuild so the index only ever swaps in finished work.
public struct IndexedDocument: Sendable {
    public var path: String
    public var title: String
    public var preview: String
    public var tokens: [String]

    public init(url: URL, content: String) {
        let title = SearchIndex.displayTitle(for: url)
        self.path = NotePath.key(url)
        self.title = title
        self.preview = SearchIndex.preview(of: content)
        self.tokens = SearchIndex.tokenize(content, title: title)
    }
}

/// Inverted index over note text.
///
/// Documents occupy dense `Int32` slots and every distinct word lives once in a
/// shared token table, so a posting costs four bytes rather than a freshly
/// allocated copy of the note's path. Note bodies are never retained: a 160-char
/// preview covers the common case and the handful of results actually shown get
/// their snippet read back from disk.
public final class SearchIndex: @unchecked Sendable {
    fileprivate struct Doc: Sendable {
        var path: String
        var title: String
        var titleLower: String
        var preview: String
        var previewLower: String
        var tokens: [Int32]     // sorted token ids, for eviction and scoring
    }

    /// How many results get a snippet read from disk; the rest use the preview.
    private static let snippetBudget = 12
    private static let maxTokenLength = 64

    private let lock = NSLock()
    private var docs: [Doc?] = []
    private var docIDByPath: [String: Int32] = [:]
    private var freeSlots: [Int32] = []
    private var tokenID: [String: Int32] = [:]
    private var tokenText: [String] = []
    private var postings: [[Int32]] = []
    /// Token ids ordered by their text, so prefix queries binary-search a range.
    private var sortedTokens: [Int32] = []
    private var sortedTokensDirty = false

    public init() {}

    // MARK: Stats

    public struct Stats: Equatable, Sendable {
        public var documents = 0
        public var tokens = 0
        public var postings = 0
        /// Rough resident cost of the index structures, in bytes.
        public var approximateBytes = 0
    }

    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        var s = Stats()
        s.documents = docIDByPath.count
        s.tokens = tokenText.count
        var titleBytes = 0
        for case let doc? in docs {
            s.postings += doc.tokens.count
            titleBytes += doc.title.utf8.count + doc.preview.utf8.count + doc.path.utf8.count
        }
        var tokenBytes = 0
        for text in tokenText { tokenBytes += text.utf8.count + 16 }
        s.approximateBytes = s.postings * 8 + tokenBytes + titleBytes + s.documents * 96
        return s
    }

    // MARK: Building

    public func clear() {
        lock.lock()
        docs.removeAll(keepingCapacity: false)
        docIDByPath.removeAll(keepingCapacity: false)
        freeSlots.removeAll(keepingCapacity: false)
        tokenID.removeAll(keepingCapacity: false)
        tokenText.removeAll(keepingCapacity: false)
        postings.removeAll(keepingCapacity: false)
        sortedTokens.removeAll(keepingCapacity: false)
        sortedTokensDirty = false
        lock.unlock()
    }

    /// Accumulates an index off the main thread. The coordinator folds each
    /// chunk of parsed notes in as it lands and drops the chunk, so peak
    /// allocation is one chunk of token strings rather than the whole vault's.
    public struct Builder: Sendable {
        fileprivate var docs: [Doc?] = []
        fileprivate var byPath: [String: Int32] = [:]
        fileprivate var tokenID: [String: Int32] = [:]
        fileprivate var tokenText: [String] = []
        fileprivate var postings: [[Int32]] = []

        public init(expectedDocuments: Int = 0) {
            docs.reserveCapacity(expectedDocuments)
            byPath.reserveCapacity(expectedDocuments)
        }

        public var count: Int { byPath.count }

        public mutating func add(_ input: IndexedDocument) {
            let path = input.path
            guard byPath[path] == nil else { return }
            let id = Int32(docs.count)
            var ids: [Int32] = []
            ids.reserveCapacity(input.tokens.count)
            for token in input.tokens {
                let tid: Int32
                if let existing = tokenID[token] {
                    tid = existing
                } else {
                    tid = Int32(tokenText.count)
                    tokenID[token] = tid
                    tokenText.append(token)
                    postings.append([])
                }
                ids.append(tid)
                postings[Int(tid)].append(id)
            }
            ids.sort()
            docs.append(Doc(
                path: path,
                title: input.title,
                titleLower: input.title.lowercased(),
                preview: input.preview,
                previewLower: input.preview.lowercased(),
                tokens: ids
            ))
            byPath[path] = id
        }

        /// Appended posting lists carry up to 2x the capacity they need.
        /// Copying them to exact size before install gives back ~2 MB on a
        /// 2,000-note vault.
        fileprivate mutating func shrink() {
            for i in postings.indices where postings[i].capacity > postings[i].count {
                var exact = [Int32]()
                exact.reserveCapacity(postings[i].count)
                exact.append(contentsOf: postings[i])
                postings[i] = exact
            }
        }
    }

    /// Atomically replace the whole index with a finished build.
    public func install(_ builder: Builder) {
        var builder = builder
        builder.shrink()
        lock.lock()
        docs = builder.docs
        docIDByPath = builder.byPath
        freeSlots = []
        tokenID = builder.tokenID
        tokenText = builder.tokenText
        postings = builder.postings
        sortedTokensDirty = true
        lock.unlock()
    }

    public func upsert(url: URL, content: String? = nil) {
        let ext = url.pathExtension.lowercased()
        guard ["md", "markdown", "txt"].contains(ext) else { return }
        let text = content ?? FileText.read(url)
        let input = IndexedDocument(url: url, content: text)
        lock.lock()
        applyUpsertLocked(input)
        lock.unlock()
    }

    public func remove(url: URL) {
        let path = NotePath.key(url)
        lock.lock()
        removeLocked(path: path)
        lock.unlock()
    }

    private func applyUpsertLocked(_ input: IndexedDocument) {
        let path = input.path
        removeLocked(path: path)
        let id = freeSlots.popLast() ?? Int32(docs.count)
        if Int(id) >= docs.count { docs.append(nil) }
        var ids: [Int32] = []
        ids.reserveCapacity(input.tokens.count)
        for token in input.tokens {
            let tid: Int32
            if let existing = tokenID[token] {
                tid = existing
            } else {
                tid = Int32(tokenText.count)
                tokenID[token] = tid
                tokenText.append(token)
                postings.append([])
                sortedTokensDirty = true
            }
            ids.append(tid)
            let slot = Int(tid)
            // Postings stay sorted so intersection is a linear merge.
            let at = lowerBound(postings[slot], id)
            if at == postings[slot].count || postings[slot][at] != id {
                postings[slot].insert(id, at: at)
            }
        }
        ids.sort()
        docs[Int(id)] = Doc(
            path: path,
            title: input.title,
            titleLower: input.title.lowercased(),
            preview: input.preview,
            previewLower: input.preview.lowercased(),
            tokens: ids
        )
        docIDByPath[path] = id
    }

    private func removeLocked(path: String) {
        guard let id = docIDByPath.removeValue(forKey: path),
              let doc = docs[Int(id)] else { return }
        for tid in doc.tokens {
            let slot = Int(tid)
            let at = lowerBound(postings[slot], id)
            if at < postings[slot].count, postings[slot][at] == id {
                postings[slot].remove(at: at)
            }
        }
        docs[Int(id)] = nil
        freeSlots.append(id)
    }

    // MARK: Query

    public func search(query: String, limit: Int = 60) -> [SearchResult] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        let needle = raw.lowercased()
        let terms = Self.splitTerms(needle)

        lock.lock()
        if sortedTokensDirty { rebuildSortedTokensLocked() }

        var candidates: [Int32]?
        for (i, term) in terms.enumerated() {
            // The word being typed matches as a prefix; earlier words are whole.
            let isTyping = i == terms.count - 1 && !needle.hasSuffix(" ")
            let hits = isTyping ? prefixPostingsLocked(term) : (tokenID[term].map { postings[Int($0)] } ?? [])
            candidates = candidates.map { intersect($0, hits) } ?? hits
            if candidates?.isEmpty == true { break }
        }
        // Mid-word matches ("ndex") reach no token prefix, so fall back to a
        // scan of the token table - tens of thousands of strings, not every
        // note body like the old full-vault rescan did.
        if candidates == nil || candidates!.isEmpty {
            candidates = substringPostingsLocked(needle)
        }

        // Two phases: rank on the title alone (short, byte-compared), then pay
        // for the preview check on the handful that survive. Running a
        // case-insensitive Foundation search over every candidate's preview was
        // most of a query's cost on a broad prefix like "the".
        let needleBytes = Array(needle.utf8)
        var scored: [(Int, Int32)] = []
        scored.reserveCapacity(min(candidates?.count ?? 0, 512))
        for id in candidates ?? [] {
            guard let doc = docs[Int(id)] else { continue }
            var score = 15
            if doc.titleLower == needle { score += 100 }
            else if doc.titleLower.utf8.starts(with: needleBytes) { score += 80 }
            else if Self.contains(doc.titleLower, needleBytes) { score += 50 }
            scored.append((score, id))
        }
        scored.sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            let a = docs[Int(lhs.1)]?.title ?? ""
            let b = docs[Int(rhs.1)]?.title ?? ""
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        let previewWindow = min(scored.count, limit * 2)
        for i in 0..<previewWindow {
            guard let doc = docs[Int(scored[i].1)] else { continue }
            if Self.contains(doc.previewLower, needleBytes) { scored[i].0 += 10 }
        }
        scored[0..<previewWindow].sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            let a = docs[Int(lhs.1)]?.title ?? ""
            let b = docs[Int(rhs.1)]?.title ?? ""
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        if scored.count > limit { scored.removeSubrange(limit...) }
        let picked = scored.compactMap { docs[Int($0.1)] }
        lock.unlock()

        // Reading happens outside the lock so a slow disk never blocks writers.
        return picked.enumerated().map { position, doc in
            let url = URL(fileURLWithPath: doc.path)
            let item = FileItem(url: url, isDirectory: false)
            let detail = position < Self.snippetBudget
                ? Self.snippet(for: url, matching: raw)
                : nil
            return SearchResult(
                id: item.id,
                fileItem: item,
                title: doc.title,
                snippet: detail?.snippet ?? doc.preview,
                lineMatch: detail?.line
            )
        }
    }

    /// Union of every posting list whose token starts with `prefix`.
    ///
    /// Accumulated into a bitmap over document ids: re-merging sorted arrays
    /// token by token was quadratic, and a common prefix like "the" matches
    /// dozens of tokens covering most of the vault.
    private func prefixPostingsLocked(_ prefix: String) -> [Int32] {
        guard !prefix.isEmpty else { return [] }
        var mask = [UInt64](repeating: 0, count: (docs.count + 63) / 64)
        var matched = false
        var i = lowerBoundToken(prefix)
        while i < sortedTokens.count {
            let tid = sortedTokens[i]
            guard tokenText[Int(tid)].hasPrefix(prefix) else { break }
            for id in postings[Int(tid)] { mask[Int(id) >> 6] |= 1 << UInt64(id & 63) }
            matched = true
            i += 1
        }
        return matched ? Self.ids(from: mask) : []
    }

    private func substringPostingsLocked(_ needle: String) -> [Int32] {
        guard needle.count >= 2 else { return [] }
        let bytes = Array(needle.utf8)
        var mask = [UInt64](repeating: 0, count: (docs.count + 63) / 64)
        var matched = false
        for (tid, text) in tokenText.enumerated() where Self.contains(text, bytes) {
            for id in postings[tid] { mask[Int(id) >> 6] |= 1 << UInt64(id & 63) }
            matched = true
        }
        return matched ? Self.ids(from: mask) : []
    }

    private static func ids(from mask: [UInt64]) -> [Int32] {
        var out: [Int32] = []
        for (word, bits) in mask.enumerated() where bits != 0 {
            var b = bits
            while b != 0 {
                let bit = b.trailingZeroBitCount
                out.append(Int32(word * 64 + bit))
                b &= b - 1
            }
        }
        return out
    }

    /// Byte-level substring test. `String.contains` walks graphemes, which is
    /// far too slow across a whole token table.
    private static func contains(_ haystack: String, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        var copy = haystack
        return copy.withUTF8 { buf in
            guard needle.count <= buf.count else { return false }
            let first = needle[0]
            var i = 0
            let limit = buf.count - needle.count
            while i <= limit {
                if buf[i] == first {
                    var k = 1
                    while k < needle.count, buf[i + k] == needle[k] { k += 1 }
                    if k == needle.count { return true }
                }
                i += 1
            }
            return false
        }
    }

    private func rebuildSortedTokensLocked() {
        sortedTokens = Array(0..<Int32(tokenText.count))
        sortedTokens.sort { tokenText[Int($0)] < tokenText[Int($1)] }
        sortedTokensDirty = false
    }

    private func lowerBoundToken(_ prefix: String) -> Int {
        var lo = 0, hi = sortedTokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokenText[Int(sortedTokens[mid])] < prefix { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: Sorted-list helpers

    private func lowerBound(_ list: [Int32], _ value: Int32) -> Int {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func intersect(_ a: [Int32], _ b: [Int32]) -> [Int32] {
        var out: [Int32] = []
        out.reserveCapacity(min(a.count, b.count))
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { out.append(a[i]); i += 1; j += 1 }
            else if a[i] < b[j] { i += 1 }
            else { j += 1 }
        }
        return out
    }

    // MARK: Text helpers

    public static func displayTitle(for url: URL) -> String {
        FileItem(url: url, isDirectory: false).displayTitle
    }

    static func preview(of content: String) -> String {
        var out = ""
        out.reserveCapacity(170)
        var lastWasSpace = false
        for ch in content {
            if out.count >= 160 { break }
            if ch == "\n" || ch == "\r" || ch == "\t" {
                if !lastWasSpace && !out.isEmpty { out.append(" "); lastWasSpace = true }
            } else {
                out.append(ch)
                lastWasSpace = ch == " "
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func tokenize(_ content: String, title: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func take(_ text: String) {
            var current = ""
            func flush() {
                guard !current.isEmpty else { return }
                if current.utf8.count <= maxTokenLength, seen.insert(current).inserted {
                    out.append(current)
                }
                current.removeAll(keepingCapacity: true)
            }
            for ch in text.lowercased() {
                if ch.isLetter || ch.isNumber { current.append(ch) } else { flush() }
            }
            flush()
        }
        take(title)
        take(content)
        return out
    }

    private static func splitTerms(_ lowercased: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in lowercased {
            if ch.isLetter || ch.isNumber { current.append(ch) }
            else if !current.isEmpty { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func snippet(for url: URL, matching raw: String) -> (snippet: String, line: String?)? {
        let content = FileText.read(url)
        guard !content.isEmpty, let range = content.range(of: raw, options: [.caseInsensitive]) else { return nil }
        let start = content.index(range.lowerBound, offsetBy: -40, limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(range.upperBound, offsetBy: 60, limitedBy: content.endIndex) ?? content.endIndex
        let snippet = "…" + content[start..<end].replacingOccurrences(of: "\n", with: " ") + "…"
        let lineStart = content[..<range.lowerBound].lastIndex(of: "\n").map { content.index(after: $0) } ?? content.startIndex
        let lineEnd = content[range.upperBound...].firstIndex(of: "\n") ?? content.endIndex
        return (snippet, String(content[lineStart..<lineEnd]).trimmingCharacters(in: .whitespaces))
    }
}
