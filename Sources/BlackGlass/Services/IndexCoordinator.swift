import Foundation

/// Owns indexing for the active vault.
///
/// Both indexes are fed from a single walk of the vault: every note is read and
/// parsed once, not once per index. Progress is published on a throttle so a
/// 2,000-note rebuild costs a few dozen view updates instead of a few thousand.
@MainActor
public final class IndexCoordinator: ObservableObject {
    public enum Phase: String, Sendable {
        case idle, scanning, indexing

        public var label: String {
            switch self {
            case .idle: "Idle"
            case .scanning: "Scanning vault"
            case .indexing: "Indexing notes"
            }
        }
    }

    public struct Status: Equatable, Sendable {
        public var phase: Phase = .idle
        public var filesDone = 0
        public var filesTotal = 0
        public var bytesRead = 0
        public var startedAt: Date?
        public var finishedAt: Date?
        /// Wall time of the last completed rebuild.
        public var lastDuration: TimeInterval = 0
        public var vaultName = ""

        public var isRunning: Bool { phase != .idle }

        public var fraction: Double {
            guard filesTotal > 0 else { return 0 }
            return min(1, Double(filesDone) / Double(filesTotal))
        }

        public var percent: Int { Int((fraction * 100).rounded()) }

        /// Linear extrapolation from files completed so far.
        public var estimatedRemaining: TimeInterval? {
            guard phase == .indexing, let startedAt, filesDone > 20, filesTotal > filesDone else { return nil }
            let elapsed = Date().timeIntervalSince(startedAt)
            let perFile = elapsed / Double(filesDone)
            return perFile * Double(filesTotal - filesDone)
        }
    }

    @Published public private(set) var status = Status()
    @Published public private(set) var searchStats = SearchIndex.Stats()
    @Published public private(set) var indexedNotes = 0
    @Published public private(set) var attachmentCount = 0
    @Published public private(set) var wikiBytes = 0

    /// Bytes of note text the last rebuild passed through.
    @Published public private(set) var corpusBytes = 0

    public var approximateBytes: Int { searchStats.approximateBytes + wikiBytes }

    private let search: SearchIndex
    private let wiki: WikiIndex
    private var task: Task<Void, Never>?

    init(search: SearchIndex, wiki: WikiIndex) {
        self.search = search
        self.wiki = wiki
    }

    // MARK: Driving

    public func rebuild(vault: URL, name: String) {
        task?.cancel()
        var next = Status()
        next.phase = .scanning
        next.startedAt = Date()
        next.vaultName = name
        next.lastDuration = status.lastDuration
        status = next

        // Captured strongly: the coordinator outlives any rebuild, and a weak
        // capture cannot cross into the @Sendable progress callback.
        task = Task { [search, wiki] in
            let started = Date()
            let files = await VaultWalk.enumerate(vault)
            if Task.isCancelled { return }
            self.status.phase = .indexing
            self.status.filesTotal = files.notes.count

            let progress: @Sendable (Int, Int) -> Void = { done, bytes in
                Task { @MainActor in
                    guard self.status.phase == .indexing else { return }
                    self.status.filesDone = max(self.status.filesDone, done)
                    self.status.bytesRead = max(self.status.bytesRead, bytes)
                }
            }
            let parsed = await VaultWalk.parse(files.notes, vault: vault, progress: progress)
            if Task.isCancelled { return }

            await Self.install(parsed: parsed, files: files, vault: vault, search: search, wiki: wiki)
            if Task.isCancelled { return }

            self.status.phase = .idle
            self.status.filesDone = files.notes.count
            self.status.filesTotal = files.notes.count
            self.status.bytesRead = parsed.bytes
            self.status.finishedAt = Date()
            self.status.lastDuration = Date().timeIntervalSince(started)
            self.corpusBytes = parsed.bytes
            self.attachmentCount = files.attachmentCount
            self.refreshStats()
        }
    }

    /// Installing touches large dictionaries; keep it off the main actor.
    private nonisolated static func install(
        parsed: VaultWalk.Parsed,
        files: VaultWalk.Files,
        vault: URL,
        search: SearchIndex,
        wiki: WikiIndex
    ) async {
        search.install(parsed.builder)
        wiki.install(records: parsed.records, fileNames: files.byName, vault: vault)
    }

    public func cancel() {
        task?.cancel()
        task = nil
        if status.phase != .idle {
            status.phase = .idle
            status.finishedAt = Date()
        }
    }

    public func clear() {
        cancel()
        search.clear()
        wiki.clear()
        status = Status()
        refreshStats()
    }

    /// Incremental edit. Cheap enough to run inline; no rebuild.
    public func noteChanged(url: URL, content: String, vault: URL) {
        search.upsert(url: url, content: content)
        wiki.upsert(url: url, content: content, vault: vault)
        scheduleStatsRefresh()
    }

    public func noteAdded(url: URL, vault: URL) {
        let content = FileText.read(url)
        noteChanged(url: url, content: content, vault: vault)
    }

    public func noteRemoved(url: URL) {
        search.remove(url: url)
        wiki.remove(url: url)
        scheduleStatsRefresh()
    }

    public func noteMoved(from old: URL, to new: URL, vault: URL) {
        search.remove(url: old)
        wiki.remove(url: old)
        noteAdded(url: new, vault: vault)
    }

    // MARK: Stats

    private var statsTask: Task<Void, Never>?

    /// Walking the tables is O(index), so coalesce bursts of edits.
    private func scheduleStatsRefresh() {
        statsTask?.cancel()
        statsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshStats()
        }
    }

    public func refreshStats() {
        searchStats = search.stats
        indexedNotes = searchStats.documents
        wikiBytes = wiki.approximateBytes
    }
}

// MARK: - Vault walking

enum VaultWalk {
    struct Files: Sendable {
        var notes: [URL] = []
        /// Every file in the vault by lowercased name, for attachment links.
        var byName: [String: [String]] = [:]
        var attachmentCount = 0
    }

    struct Parsed: Sendable {
        var builder = SearchIndex.Builder()
        var records: [NoteRecord] = []
        var bytes = 0
    }

    static let noteExtensions: Set<String> = ["md", "markdown", "txt"]

    /// The async wrapper puts the walk on the cooperative pool; the body stays
    /// synchronous because DirectoryEnumerator cannot be iterated from async code.
    static func enumerate(_ vault: URL) async -> Files { enumerateSync(vault) }

    private static func enumerateSync(_ vault: URL) -> Files {
        var files = Files()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: vault,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return files }
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { return files }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let standardized = fileURL.standardizedFileURL
            files.byName[standardized.lastPathComponent.lowercased(), default: []].append(NotePath.key(standardized))
            if noteExtensions.contains(standardized.pathExtension.lowercased()) {
                files.notes.append(standardized)
            } else {
                files.attachmentCount += 1
            }
        }
        return files
    }

    /// Files per unit of work. Small, so the amount of note text alive at once
    /// stays bounded no matter how large the vault is.
    private static let chunkSize = 32

    /// Read and parse with bounded concurrency, folding each chunk into the
    /// index as it lands so the chunk's text and strings are released at once.
    /// Splitting the vault into one chunk per core instead held every note in
    /// memory simultaneously.
    static func parse(
        _ notes: [URL],
        vault: URL,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> Parsed {
        var out = Parsed()
        guard !notes.isEmpty else { return out }
        out.builder = SearchIndex.Builder(expectedDocuments: notes.count)
        var records = [NoteRecord?](repeating: nil, count: notes.count)

        var ranges: [Range<Int>] = []
        var start = 0
        while start < notes.count {
            ranges.append(start..<min(start + chunkSize, notes.count))
            start += chunkSize
        }

        let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        var done = 0
        var bytes = 0

        await withTaskGroup(of: (Int, [IndexedDocument], [NoteRecord], Int).self) { group in
            func schedule(_ range: Range<Int>) {
                group.addTask {
                    var docs: [IndexedDocument] = []
                    var recs: [NoteRecord] = []
                    var chunkBytes = 0
                    docs.reserveCapacity(range.count)
                    recs.reserveCapacity(range.count)
                    for i in range {
                        if Task.isCancelled { break }
                        let url = notes[i]
                        let content = FileText.read(url)
                        chunkBytes += content.utf8.count
                        docs.append(IndexedDocument(url: url, content: content))
                        recs.append(WikiIndex.makeRecord(url: url, vault: vault, content: content))
                    }
                    return (range.lowerBound, docs, recs, chunkBytes)
                }
            }

            var nextChunk = 0
            while nextChunk < ranges.count && nextChunk < workers {
                schedule(ranges[nextChunk])
                nextChunk += 1
            }
            for await (offset, docs, recs, chunkBytes) in group {
                for doc in docs { out.builder.add(doc) }
                for (k, rec) in recs.enumerated() { records[offset + k] = rec }
                done += docs.count
                bytes += chunkBytes
                progress(done, bytes)
                if nextChunk < ranges.count {
                    schedule(ranges[nextChunk])
                    nextChunk += 1
                }
            }
        }
        // Trim the builder here, where the walk is still its only owner. Left
        // to `install`, the trim mutated a copy while this one was alive, so
        // every unshrunk posting list stayed resident next to its replacement.
        out.builder.shrink()
        out.bytes = bytes
        out.records = records.compactMap { $0 }
        return out
    }
}
