import Foundation
import SwiftUI
import CoreGraphics

// MARK: - Graph data

/// Result of a vault scan. Node identity is the vault-relative path, but edges
/// reference nodes by index so the layout never hashes a string in a hot loop.
struct GraphData: Sendable {
    var ids: [String] = []
    var titles: [String] = []
    var edgeA: [Int32] = []
    var edgeB: [Int32] = []
    var degree: [Int32] = []
    var indexByID: [String: Int] = [:]

    var nodeCount: Int { ids.count }
    var edgeCount: Int { edgeA.count }
}

// MARK: - Scanning

enum GraphBuilder {
    /// Node table plus the lookup indexes link resolution needs.
    private struct Tables {
        var data = GraphData()
        var byPath: [String: Int] = [:]
        var byStem: [String: [Int]] = [:]
        var folderOf: [String] = []
        var indexOfFile: [Int] = []
    }

    /// Walks the vault, extracts links, and resolves them to node indices.
    /// `async` and non-isolated, so it runs on the cooperative pool rather than
    /// the main actor and inherits cancellation from its caller.
    static func build(
        vault: URL,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> GraphData {
        let files = GraphScanner.noteURLs(in: vault)
        if Task.isCancelled || files.isEmpty { return GraphData() }
        progress?(0, files.count)
        var tables = makeTables(files: files, vault: vault)
        if Task.isCancelled { return GraphData() }

        // Read and parse in parallel chunks. The old code spawned one detached
        // task per file and published progress after every one, which cost more
        // than the parsing itself did.
        let workers = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let chunkSize = max(24, (files.count + workers - 1) / workers)
        var linksByFile = [[WikiTarget]](repeating: [], count: files.count)
        await withTaskGroup(of: (Int, [[WikiTarget]]).self) { group in
            var start = 0
            while start < files.count {
                let range = start..<min(start + chunkSize, files.count)
                group.addTask {
                    var out: [[WikiTarget]] = []
                    out.reserveCapacity(range.count)
                    for i in range {
                        if Task.isCancelled { break }
                        out.append(OFMParser.extractLinksFast(read(files[i])))
                    }
                    return (range.lowerBound, out)
                }
                start = range.upperBound
            }
            var done = 0
            for await (offset, out) in group {
                for (k, links) in out.enumerated() { linksByFile[offset + k] = links }
                done += out.count
                progress?(done, files.count)
            }
        }
        if Task.isCancelled { return GraphData() }
        return assemble(&tables, links: linksByFile)
    }

    /// Blocking variant for the embedded web server, which answers on the main
    /// thread and cannot await.
    static func buildSync(vault: URL) -> GraphData {
        let files = GraphScanner.noteURLs(in: vault)
        if files.isEmpty { return GraphData() }
        var tables = makeTables(files: files, vault: vault)
        let links = files.map { OFMParser.extractLinksFast(read($0)) }
        return assemble(&tables, links: links)
    }

    private static func read(_ url: URL) -> String {
        FileText.read(url)
    }

    private static func makeTables(files: [URL], vault: URL) -> Tables {
        var t = Tables()
        t.data.ids.reserveCapacity(files.count)
        t.data.titles.reserveCapacity(files.count)
        t.data.indexByID.reserveCapacity(files.count)
        t.byPath.reserveCapacity(files.count)
        t.folderOf.reserveCapacity(files.count)
        t.indexOfFile = [Int](repeating: -1, count: files.count)

        for (f, url) in files.enumerated() {
            let rel = GraphScanner.relative(url, vault: vault)
            let key = rel.lowercased()
            // Duplicate relative paths would later trap a uniquing Dictionary.
            if let existing = t.byPath[key] { t.indexOfFile[f] = existing; continue }
            let index = t.data.ids.count
            let title = url.deletingPathExtension().lastPathComponent
            t.data.ids.append(rel)
            t.data.titles.append(title)
            t.data.indexByID[rel] = index
            t.byPath[key] = index
            t.byStem[title.lowercased(), default: []].append(index)
            t.folderOf.append(GraphScanner.parentPath(of: rel))
            t.indexOfFile[f] = index
        }
        return t
    }

    private static func assemble(_ t: inout Tables, links: [[WikiTarget]]) -> GraphData {
        var degree = [Int32](repeating: 0, count: t.data.ids.count)
        // Collapses parallel and reciprocal links into one undirected edge, so a
        // note that references a neighbour ten times pulls on it once.
        var seen = Set<Int64>()
        seen.reserveCapacity(links.count * 2)
        for f in 0..<min(links.count, t.indexOfFile.count) {
            let from = t.indexOfFile[f]
            guard from >= 0 else { continue }
            let folder = t.folderOf[from]
            for link in links[f] where !link.dest.isEmpty && !link.isMedia {
                guard let to = resolve(
                    link.dest, folder: folder,
                    byPath: t.byPath, byStem: t.byStem, ids: t.data.ids
                ), to != from else { continue }
                let key = Int64(min(from, to)) << 32 | Int64(max(from, to))
                guard seen.insert(key).inserted else { continue }
                t.data.edgeA.append(Int32(from))
                t.data.edgeB.append(Int32(to))
                degree[from] += 1
                degree[to] += 1
            }
        }
        t.data.degree = degree
        return t.data
    }

    /// Resolve a link target to a node index: sibling first, then vault root,
    /// then by title. All string lookups - no filesystem access.
    private static func resolve(
        _ dest: String,
        folder: String,
        byPath: [String: Int],
        byStem: [String: [Int]],
        ids: [String]
    ) -> Int? {
        let cleaned = dest
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleaned.isEmpty { return nil }

        let ext = (cleaned as NSString).pathExtension.lowercased()
        let candidates: [String] = ["md", "markdown", "txt"].contains(ext)
            ? [cleaned]
            : [cleaned + ".md", cleaned + ".markdown", cleaned]

        for name in candidates {
            if let hit = byPath[GraphScanner.join(folder, name).lowercased()] { return hit }
        }
        for name in candidates {
            if let hit = byPath[GraphScanner.normalize(name).lowercased()] { return hit }
        }

        let stem = (cleaned as NSString).lastPathComponent
        let bare = ((stem as NSString).pathExtension.isEmpty
            ? stem
            : (stem as NSString).deletingPathExtension).lowercased()
        guard let hits = byStem[bare], !hits.isEmpty else { return nil }
        if hits.count == 1 { return hits[0] }
        return hits.min { ids[$0].count < ids[$1].count }
    }
}

enum GraphScanner {
    static func noteURLs(in vault: URL) -> [URL] {
        var urls: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: vault,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { continue }
            // The enumerator already fetched this; the old per-file
            // `fileExists(atPath:isDirectory:)` was a redundant stat.
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            urls.append(fileURL.standardizedFileURL)
        }
        urls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return urls
    }

    static func relative(_ url: URL, vault: URL) -> String {
        let full = url.standardizedFileURL.path
        let root = vault.standardizedFileURL.path
        if full.hasPrefix(root) {
            return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    /// Vault-relative directory containing `path` ("" at the vault root).
    static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Resolve `.` and `..` in a vault-relative path without touching disk.
    static func normalize(_ path: String) -> String {
        guard path.contains("./") || path.hasSuffix("/.") || path.hasSuffix("/..") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? normalize(name) : normalize(folder + "/" + name)
    }

    /// Node/edge snapshot for the embedded web view.
    static func snapshot(vault: URL) -> (nodes: [GraphNodeInfo], edges: [GraphEdgeInfo]) {
        let data = GraphBuilder.buildSync(vault: vault)
        let nodes = (0..<data.nodeCount).map {
            GraphNodeInfo(title: data.titles[$0], path: data.ids[$0], unresolved: false)
        }
        let edges = (0..<data.edgeCount).map {
            GraphEdgeInfo(from: data.ids[Int(data.edgeA[$0])], to: data.ids[Int(data.edgeB[$0])])
        }
        return (nodes, edges)
    }
}

// MARK: - Adjacency

/// Compressed (CSR) adjacency over the undirected edge list. Built once per
/// graph so neighbour lookups and ego-graph BFS never rescan the edge arrays -
/// the hover highlight used to walk all 20k edges on every frame.
struct GraphAdjacency {
    private var start: [Int32] = []
    private var list: [Int32] = []

    init() {}

    init(nodeCount n: Int, edgeA: [Int32], edgeB: [Int32]) {
        guard n > 0 else { return }
        start = [Int32](repeating: 0, count: n + 1)
        for e in 0..<edgeA.count {
            start[Int(edgeA[e]) + 1] += 1
            start[Int(edgeB[e]) + 1] += 1
        }
        for i in 1...n { start[i] += start[i - 1] }
        list = [Int32](repeating: 0, count: Int(start[n]))
        var cursor = start
        for e in 0..<edgeA.count {
            let a = Int(edgeA[e]), b = Int(edgeB[e])
            list[Int(cursor[a])] = Int32(b); cursor[a] += 1
            list[Int(cursor[b])] = Int32(a); cursor[b] += 1
        }
    }

    func neighbours(of i: Int) -> ArraySlice<Int32> {
        guard i >= 0, i + 1 < start.count else { return [] }
        return list[Int(start[i])..<Int(start[i + 1])]
    }

    /// Node indices within `depth` hops of `root`, root included, ascending so
    /// the derived subgraph keeps the vault's own path ordering.
    func ball(around root: Int, depth: Int, nodeCount n: Int) -> [Int] {
        guard n > 0, root >= 0, root < n, start.count == n + 1 else { return [] }
        var seen = [Bool](repeating: false, count: n)
        seen[root] = true
        var out: [Int] = [root]
        var frontier: [Int32] = [Int32(root)]
        var hop = 0
        while hop < depth, !frontier.isEmpty {
            var next: [Int32] = []
            for raw in frontier {
                for nb in neighbours(of: Int(raw)) where !seen[Int(nb)] {
                    seen[Int(nb)] = true
                    next.append(nb)
                    out.append(Int(nb))
                }
            }
            frontier = next
            hop += 1
        }
        out.sort()
        return out
    }
}

// MARK: - Scoping

/// What slice of the vault the layout is showing.
enum GraphScope: Equatable {
    /// The whole vault, optionally minus the notes nothing links to.
    case global
    /// The selected note's neighbourhood, out to `localDepth` hops.
    case local
}

// MARK: - Layout

@MainActor
final class GraphEngine: ObservableObject {
    // Coarse UI state. Published, but only changes a handful of times per second.
    @Published private(set) var isBuilding = false
    @Published private(set) var scanned = 0
    @Published private(set) var total = 0
    /// Counts for the *active* (scoped) view.
    @Published private(set) var nodeCount = 0
    @Published private(set) var edgeCount = 0
    /// Counts for the whole vault, so the UI can say what scoping hid.
    @Published private(set) var sourceNodeCount = 0
    @Published private(set) var hiddenCount = 0
    /// The layout has come to rest; `TimelineView` stops ticking on this.
    @Published private(set) var isPaused = true
    /// Bumped when a freshly built graph lands, so the view knows it is new.
    @Published private(set) var generation = 0
    /// Bumped when the hovered node changes, so a settled canvas still redraws.
    @Published private(set) var hoverRevision = 0
    /// Bumped by pan/zoom/orbit. `pan` and `zoom` themselves are deliberately
    /// unpublished: framing happens inside the draw pass, and mutating
    /// published state from there is what SwiftUI warns about.
    @Published private(set) var cameraRevision = 0

    // Scoping, all published so the toolbar reflects them.
    @Published private(set) var scope: GraphScope = .global
    @Published private(set) var localDepth = 2
    /// On by default: an unlinked note is still a note, and hiding them means
    /// the note you currently have open can be missing from its own graph.
    @Published private(set) var showOrphans = true
    @Published private(set) var is3D = false
    @Published private(set) var focusID: String?

    var pan: CGSize = .zero
    var zoom: CGFloat = 1

    // Hot layout state. Never published: it changes every frame, and pushing it
    // through Combine invalidated the whole view tree 24 times a second.
    /// The whole vault as built. `data` is a derived, scoped view over it.
    private(set) var source = GraphData()
    private var sourceAdjacency = GraphAdjacency()
    private(set) var data = GraphData()
    private var adjacency = GraphAdjacency()
    private(set) var px: [Double] = []
    private(set) var py: [Double] = []
    private(set) var pz: [Double] = []
    private var vx: [Double] = []
    private var vy: [Double] = []
    private var vz: [Double] = []
    private(set) var radius: [Double] = []
    /// Vault-wide degree of each active node. A note on the edge of an ego
    /// graph keeps the size its real link count earns, which is the hint that
    /// there is more graph out past the frontier.
    private(set) var weight: [Int32] = []
    private var labelText: [String] = []
    /// Node indices by descending vault degree; label placement walks this.
    private(set) var labelOrder: [Int] = []

    // Projected positions. 2D is just the identity projection, so every
    // consumer - drawing, framing, hit testing - reads these and never has to
    // know whether the camera is flat or not.
    private var sx: [Double] = []
    private var sy: [Double] = []
    private var sd: [Double] = []      // per-node perspective scale
    private var sz: [Double] = []      // camera-space depth
    private var depthMin = 0.0
    private var depthMax = 1.0
    private var projectionDirty = true

    // 3D camera.
    private(set) var yaw = 0.62
    private(set) var pitch = 0.32
    private(set) var cameraDistance = 900.0

    private var alpha: Double = 0
    private var alphaTarget: Double = 0
    private var pinned: Int?
    private var tree = BHTree()
    private var scratch: [Int32] = []
    private var task: Task<Void, Never>?

    // Framing. The old code re-fit on every tick while `!userAdjusted`, which
    // made the whole graph visibly breathe for the ~5s it took to settle.
    private var needsFit = false
    private var pendingFitSlack: CGFloat = 1

    // Hit testing.
    private var grid = SpatialGrid()
    private var gridDirty = true
    private var maxRadiusWorld = 4.0

    // Selection focus.
    private var focusMask: [Bool] = []
    private var focusKey = -2
    private var focusActive = false

    // Screen-space label placement.
    private var placedLabels: [Int] = []
    private var labelKey = LabelKey()
    private var lastLabelLayout: TimeInterval = 0
    private var layoutGeneration = 0
    private var lastMatching: Set<String>?
    private var matchIndex: Set<Int>?
    private var matchRevision = 0

    /// Canvas size in points, refreshed on every draw so the engine can frame
    /// and hit-test without the view passing geometry around.
    private(set) var viewSize: CGSize = .zero
    /// Node under the pointer.
    private(set) var hoveredIndex: Int?
    /// Set by any pan, zoom, orbit or node drag; stops the camera auto-framing.
    private(set) var userAdjusted = false
    private var dragIndex: Int?
    private var panning = false
    private var lastDragPoint: CGPoint = .zero
    /// Called when a click lands on a node, with its vault-relative path.
    var onOpenNode: ((String) -> Void)?
    /// Called after a full vault scan finishes, so the caller can cache the
    /// result — a fresh build re-walks and re-parses every note, which is
    /// the whole reason a same-session reopen should skip it via `start(cached:)`.
    var onBuilt: ((GraphData) -> Void)?

    /// Pointer distance, in points, that still counts as touching a node.
    private static let hitSlop: CGFloat = 12

    // d3-force's schedule: ~300 ticks from a full reheat to rest.
    private static let alphaDecay = 0.0228
    private static let alphaMin = 0.0015
    private static let velocityDecay = 0.6
    private static let repelStrength = -180.0
    private static let linkDistance = 46.0
    private static let linkStrength = 0.5
    private static let gravity = 0.07
    private static let theta2 = 0.81
    private static let maxEdgesDrawn = 60_000

    /// Labels are drawn into the untransformed context, so this is real points
    /// at any zoom rather than a world size that shrinks to nothing.
    private static let labelFontSize: CGFloat = 11
    private static let maxLabelsPlaced = 120
    private static let maxLabelCandidates = 420
    /// While the layout is still moving, labels are re-placed on this cadence
    /// instead of every frame, so the visible set drifts rather than strobes.
    private static let labelRelayoutInterval: TimeInterval = 0.3
    /// Floor in *screen* points, so a node never disappears when zoomed out.
    private static let minScreenRadius: Double = 1.5
    private static let nearPlane = 60.0

    // MARK: Lifecycle

    /// `cached`, when given, is installed immediately with no rescan — reopening
    /// Graph mode on a vault that hasn't changed since the last build shouldn't
    /// re-walk and re-parse every note just to reproduce the same graph.
    func start(vault: URL, cached: GraphData? = nil) {
        task?.cancel()
        pan = .zero
        zoom = 1
        if let cached {
            isBuilding = false
            scanned = 0
            total = 0
            install(cached)
            generation &+= 1
            return
        }
        isBuilding = true
        scanned = 0
        total = 0
        install(GraphData())
        task = Task { [weak self] in
            let built = await GraphBuilder.build(vault: vault) { [weak self] done, count in
                Task { @MainActor in self?.report(scanned: done, total: count) }
            }
            guard let self, !Task.isCancelled else { return }
            self.install(built)
            self.isBuilding = false
            self.generation &+= 1
            self.onBuilt?(built)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isBuilding = false
        isPaused = true
    }

    private func report(scanned done: Int, total count: Int) {
        // Progress arrives per chunk, not per file, so this is cheap.
        if count != total { total = count }
        if done > scanned { scanned = done }
    }

    /// Installs a freshly built vault graph and derives the active scope from it.
    private func install(_ built: GraphData) {
        source = built
        sourceAdjacency = GraphAdjacency(
            nodeCount: built.nodeCount, edgeA: built.edgeA, edgeB: built.edgeB
        )
        sourceNodeCount = built.nodeCount
        applyScope()
    }

    // MARK: Scoping

    func setScope(_ next: GraphScope) {
        guard next != scope else { return }
        scope = next
        applyScope()
    }

    func setLocalDepth(_ next: Int) {
        let clamped = min(max(next, 1), 3)
        guard clamped != localDepth else { return }
        localDepth = clamped
        if scope == .local { applyScope() }
    }

    func setShowOrphans(_ next: Bool) {
        guard next != showOrphans else { return }
        showOrphans = next
        if scope == .global { applyScope() }
    }

    /// The note the ego graph is centred on. Re-scopes in place: the vault
    /// graph is already built, so this is a filter, not a rescan.
    func setFocus(_ id: String?) {
        guard id != focusID else { return }
        focusID = id
        if scope == .local { applyScope() }
    }

    private func applyScope() {
        guard source.nodeCount > 0 else {
            load(GraphData(), weight: [])
            hiddenCount = 0
            return
        }
        let keep: [Int]
        switch scope {
        case .global:
            // A derived filter, never a rebuild, so toggling orphans is instant.
            keep = showOrphans
                ? Array(0..<source.nodeCount)
                : (0..<source.nodeCount).filter { source.degree[$0] > 0 }
        case .local:
            guard let focusID, let root = source.indexByID[focusID] else {
                load(GraphData(), weight: [])
                hiddenCount = source.nodeCount
                return
            }
            // Orphan filtering is meaningless here: BFS from the focus can only
            // reach linked notes, and the focus itself must survive even when
            // nothing links to it.
            keep = sourceAdjacency.ball(
                around: root, depth: localDepth, nodeCount: source.nodeCount
            )
        }
        let (filtered, degrees) = Self.subgraph(of: source, keeping: keep)
        hiddenCount = source.nodeCount - filtered.nodeCount
        load(filtered, weight: degrees)
    }

    /// Compacts `keep` into a standalone graph. Node identity (the vault path)
    /// is preserved so positions and the selection survive a re-scope; only the
    /// edge endpoints are remapped.
    private static func subgraph(
        of source: GraphData, keeping keep: [Int]
    ) -> (GraphData, [Int32]) {
        var out = GraphData()
        guard !keep.isEmpty else { return (out, []) }
        var map = [Int32](repeating: -1, count: source.nodeCount)
        out.ids.reserveCapacity(keep.count)
        out.titles.reserveCapacity(keep.count)
        out.indexByID.reserveCapacity(keep.count)
        var weight: [Int32] = []
        weight.reserveCapacity(keep.count)
        for old in keep {
            guard old >= 0, old < source.nodeCount, map[old] < 0 else { continue }
            let newIndex = out.ids.count
            map[old] = Int32(newIndex)
            out.ids.append(source.ids[old])
            out.titles.append(source.titles[old])
            out.indexByID[source.ids[old]] = newIndex
            weight.append(source.degree[old])
        }
        var degree = [Int32](repeating: 0, count: out.ids.count)
        for e in 0..<source.edgeA.count {
            let a = map[Int(source.edgeA[e])]
            let b = map[Int(source.edgeB[e])]
            guard a >= 0, b >= 0 else { continue }
            out.edgeA.append(a)
            out.edgeB.append(b)
            degree[Int(a)] += 1
            degree[Int(b)] += 1
        }
        out.degree = degree
        return (out, weight)
    }

    /// Installs an active graph and reseeds the layout.
    private func load(_ next: GraphData, weight degrees: [Int32]) {
        // Carry positions across a re-scope by path, so stepping from one note's
        // neighbourhood to a neighbour's doesn't throw the shared nodes across
        // the canvas.
        var carry: [String: (Double, Double, Double)] = [:]
        if !data.ids.isEmpty, px.count == data.ids.count {
            carry.reserveCapacity(data.ids.count)
            for i in 0..<data.ids.count { carry[data.ids[i]] = (px[i], py[i], pz[i]) }
        }

        data = next
        weight = degrees.count == next.nodeCount
            ? degrees
            : [Int32](repeating: 0, count: next.nodeCount)
        let n = next.nodeCount
        adjacency = GraphAdjacency(nodeCount: n, edgeA: next.edgeA, edgeB: next.edgeB)
        px = [Double](repeating: 0, count: n)
        py = [Double](repeating: 0, count: n)
        pz = [Double](repeating: 0, count: n)
        vx = [Double](repeating: 0, count: n)
        vy = [Double](repeating: 0, count: n)
        vz = [Double](repeating: 0, count: n)
        sx = [Double](repeating: 0, count: n)
        sy = [Double](repeating: 0, count: n)
        sd = [Double](repeating: 1, count: n)
        sz = [Double](repeating: 0, count: n)
        radius = [Double](repeating: 4, count: n)
        labelText = [String](repeating: "", count: n)
        focusMask = [Bool](repeating: false, count: n)
        maxRadiusWorld = 4
        // Phyllotaxis seed: an even spread that gives the springs a head start.
        for i in 0..<n {
            if let seed = carry[next.ids[i]] {
                px[i] = seed.0; py[i] = seed.1; pz[i] = seed.2
            } else {
                let angle = Double(i) * 2.399963
                let r = 12 * (Double(i) + 1).squareRoot()
                px[i] = cos(angle) * r
                py[i] = sin(angle) * r
                pz[i] = is3D ? Self.depthSeed(i) : 0
            }
            radius[i] = Self.radiusFor(degree: self.weight[i])
            maxRadiusWorld = max(maxRadiusWorld, radius[i])
            labelText[i] = Self.labelString(next.titles[i])
        }
        labelOrder = (0..<n).sorted { self.weight[$0] > self.weight[$1] }
        scratch.reserveCapacity(64)
        nodeCount = n
        edgeCount = next.edgeCount
        pinned = nil
        dragIndex = nil
        panning = false
        hoveredIndex = nil
        userAdjusted = false
        alphaTarget = 0
        alpha = n > 1 ? 1 : 0
        isPaused = n <= 1
        focusKey = -2
        placedLabels.removeAll(keepingCapacity: true)
        layoutGeneration &+= 1
        projectionDirty = true
        gridDirty = true
        // A generous first framing: the seed is far tighter than the settled
        // layout, so fitting it exactly would push the graph off-screen as it
        // expands. The settle-fit below tightens it once it stops moving.
        requestFit(slack: n > 1 ? 2.2 : 1)
    }

    /// Log-scaled with a high ceiling. The old `sqrt` curve saturated around
    /// degree 14, so a 300-link index note and a 14-link note drew identically.
    private static func radiusFor(degree d: Int32) -> Double {
        2.2 + min(19.0, 3.4 * log2(1 + Double(max(0, d))))
    }

    /// Kept short and single-line: a wrapped label is both harder to read and
    /// far harder to pack without collisions.
    private static func labelString(_ title: String) -> String {
        title.count > 26 ? String(title.prefix(25)) + "…" : title
    }

    /// Deterministic off-plane seed. With every z exactly zero the repulsion is
    /// perfectly symmetric in depth and a 3D layout would stay flat forever.
    private static func depthSeed(_ i: Int) -> Double {
        let a = Double(i) * 2.399963
        return sin(a * 1.7) * 18 + cos(a * 0.61) * 12
    }

    private func requestFit(slack: CGFloat) {
        needsFit = true
        pendingFitSlack = slack
    }

    // MARK: Simulation

    func step() {
        let n = nodeCount
        // A one-node graph has nothing to relax, so make sure the schedule
        // stops: anything that reheats it would otherwise tick forever.
        guard n > 1 else {
            if !isPaused { isPaused = true }
            return
        }
        if alpha < Self.alphaMin && alphaTarget == 0 {
            if !isPaused {
                isPaused = true
                // One last framing now that the graph has stopped moving. Fitting
                // every tick instead is what made the whole thing breathe.
                if !userAdjusted { requestFit(slack: 1) }
            }
            return
        }
        alpha += (alphaTarget - alpha) * Self.alphaDecay
        applyRepulsion()
        applyLinks()
        integrate()
        projectionDirty = true
        gridDirty = true
    }

    /// Barnes-Hut n-body repulsion. The previous version sampled every
    /// `n/220`th node pair and switched repulsion off entirely above 450 nodes,
    /// which collapsed larger vaults into a hairball.
    private func applyRepulsion() {
        let n = nodeCount
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var minZ = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        var maxZ = -Double.greatestFiniteMagnitude
        for i in 0..<n {
            minX = min(minX, px[i]); maxX = max(maxX, px[i])
            minY = min(minY, py[i]); maxY = max(maxY, py[i])
            minZ = min(minZ, pz[i]); maxZ = max(maxZ, pz[i])
        }
        let span = max(max(maxX - minX, maxY - minY), maxZ - minZ)
        let half = max(span * 0.5, 1) * 1.02
        tree.reset(
            centerX: (minX + maxX) * 0.5,
            centerY: (minY + maxY) * 0.5,
            centerZ: (minZ + maxZ) * 0.5,
            half: half, capacity: n
        )
        for i in 0..<n { tree.insert(body: Int32(i), x: px[i], y: py[i], z: pz[i]) }

        let k = Self.repelStrength * alpha
        for i in 0..<n {
            var fx = 0.0, fy = 0.0, fz = 0.0
            tree.accumulate(
                x: px[i], y: py[i], z: pz[i], body: Int32(i),
                theta2: Self.theta2, stack: &scratch
            ) { dx, dy, dz, d2, mass in
                let w = k * mass / d2
                fx += dx * w
                fy += dy * w
                fz += dz * w
            }
            vx[i] += fx
            vy[i] += fy
            vz[i] += fz
        }
    }

    private func applyLinks() {
        let a = data.edgeA, b = data.edgeB, degree = data.degree
        for e in 0..<a.count {
            let i = Int(a[e]), j = Int(b[e])
            var dx = px[j] - px[i]
            var dy = py[j] - py[i]
            var dz = pz[j] - pz[i]
            var d2 = dx * dx + dy * dy + dz * dz
            if d2 < 0.0001 {
                dx = Double((e % 7) - 3) * 0.1 + 0.05
                dy = Double((e % 5) - 2) * 0.1 + 0.05
                dz = Double((e % 3) - 1) * 0.1 + 0.05
                d2 = dx * dx + dy * dy + dz * dz
            }
            let d = d2.squareRoot()
            // Weak links between hubs, so a heavily linked index note does not
            // drag the whole vault onto itself.
            let strength = Self.linkStrength / Double(max(1, min(degree[i], degree[j])))
            let force = (d - Self.linkDistance) * alpha * strength / d
            let bias = Double(degree[i]) / Double(max(1, degree[i] + degree[j]))
            vx[i] += dx * force * (1 - bias)
            vy[i] += dy * force * (1 - bias)
            vz[i] += dz * force * (1 - bias)
            vx[j] -= dx * force * bias
            vy[j] -= dy * force * bias
            vz[j] -= dz * force * bias
        }
    }

    private func integrate() {
        let n = nodeCount
        let g = Self.gravity * alpha
        let decay = Self.velocityDecay
        for i in 0..<n {
            if i == pinned {
                vx[i] = 0; vy[i] = 0; vz[i] = 0
                continue
            }
            vx[i] -= px[i] * g
            vy[i] -= py[i] * g
            vz[i] -= pz[i] * g
            vx[i] *= decay
            vy[i] *= decay
            vz[i] *= decay
            px[i] += vx[i]
            py[i] += vy[i]
            pz[i] += vz[i]
        }
    }

    /// Nudge the layout back to life after an interaction.
    func reheat(to target: Double = 0.42) {
        alpha = max(alpha, target)
        if isPaused { isPaused = false }
    }

    // MARK: Projection

    /// 3D toggle. 2D is the identity projection, so nothing downstream branches.
    func setThreeD(_ on: Bool) {
        guard on != is3D else { return }
        is3D = on
        for i in 0..<nodeCount {
            if on {
                if pz[i] == 0 { pz[i] = Self.depthSeed(i) }
            } else {
                pz[i] = 0
                vz[i] = 0
            }
        }
        projectionDirty = true
        gridDirty = true
        userAdjusted = false
        requestFit(slack: 1)
        reheat(to: 0.6)
        cameraRevision &+= 1
    }

    func orbitBy(dx: Double, dy: Double) {
        guard is3D, dx != 0 || dy != 0 else { return }
        userAdjusted = true
        yaw += dx * 0.007
        pitch = min(max(pitch + dy * 0.006, -1.45), 1.45)
        projectionDirty = true
        gridDirty = true
        cameraRevision &+= 1
        setHover(nil)
    }

    /// Pinch in 3D moves the camera rather than scaling the picture, so the
    /// perspective actually changes.
    func dollyBy(_ factor: Double) {
        guard is3D, factor.isFinite, factor > 0 else { return }
        let next = min(max(cameraDistance * factor, 120), 200_000)
        guard next != cameraDistance else { return }
        userAdjusted = true
        cameraDistance = next
        projectionDirty = true
        gridDirty = true
        cameraRevision &+= 1
    }

    private func refreshProjection() {
        projectionDirty = false
        let n = nodeCount
        guard n > 0, sx.count == n else { return }
        guard is3D else {
            for i in 0..<n {
                sx[i] = px[i]; sy[i] = py[i]; sd[i] = 1; sz[i] = 0
            }
            depthMin = 0; depthMax = 1
            return
        }
        let cy = cos(yaw), sw = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for i in 0..<n {
            let x = px[i], y = py[i], z = pz[i]
            let x1 = x * cy + z * sw
            let z1 = -x * sw + z * cy
            let y2 = y * cp - z1 * sp
            let z2 = y * sp + z1 * cp
            // Normalised so the graph's centre plane keeps its 2D scale; only
            // the near/far halves grow and shrink around it.
            let s = cameraDistance / max(z2 + cameraDistance, Self.nearPlane)
            sx[i] = x1 * s
            sy[i] = y2 * s
            sd[i] = s
            sz[i] = z2
            lo = min(lo, z2); hi = max(hi, z2)
        }
        depthMin = lo
        depthMax = max(hi, lo + 1)
    }

    /// 0 at the nearest node, 1 at the furthest.
    private func depthNorm(_ i: Int) -> Double {
        guard is3D else { return 0 }
        return min(max((sz[i] - depthMin) / (depthMax - depthMin), 0), 1)
    }

    /// Pulls the camera back far enough that the whole cloud sits in front of it.
    private func recenterCamera() {
        let n = nodeCount
        guard n > 0 else { return }
        var extent = 1.0
        for i in 0..<n {
            extent = max(extent, (px[i] * px[i] + py[i] * py[i] + pz[i] * pz[i]).squareRoot())
        }
        cameraDistance = max(extent * 2.4, 260)
        projectionDirty = true
    }

    // MARK: Interaction

    func viewToGraph(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.width) / zoom, y: (p.y - pan.height) / zoom)
    }

    /// Canvas size, refreshed from the draw pass. Framing and hit testing read it.
    func setViewSize(_ size: CGSize) {
        viewSize = size
    }

    /// Screen position of a node, for hover cards and hit testing.
    func viewPoint(of index: Int) -> CGPoint {
        guard sx.indices.contains(index) else { return .zero }
        return CGPoint(x: sx[index] * zoom + pan.width, y: sy[index] * zoom + pan.height)
    }

    /// Screen radius of a node, floored so it never becomes sub-pixel.
    private func screenRadius(_ i: Int) -> Double {
        max(radius[i] * sd[i] * Double(zoom), Self.minScreenRadius)
    }

    /// Nearest node to a point in view space, if it is close enough to count.
    /// Backed by a uniform grid: the old linear scan ran on every `mouseMoved`,
    /// which on a 4k-node vault was a full pass at pointer frequency.
    func hitTest(viewPoint point: CGPoint) -> Int? {
        let n = nodeCount
        guard n > 0 else { return nil }
        if projectionDirty { refreshProjection() }
        if gridDirty {
            grid.build(x: sx, y: sy, count: n)
            gridDirty = false
        }
        let target = viewToGraph(point)
        let gx = Double(target.x), gy = Double(target.y)
        let z = Double(max(zoom, 0.02))
        let slop = Double(Self.hitSlop) / z
        var best = -1
        var bestD2 = Double.greatestFiniteMagnitude
        let visit: (Int) -> Void = { i in
            let dx = self.sx[i] - gx, dy = self.sy[i] - gy
            let d2 = dx * dx + dy * dy
            guard d2 < bestD2 else { return }
            let allow = slop + self.screenRadius(i) / Double(max(self.zoom, 0.0001))
            if d2 <= allow * allow { bestD2 = d2; best = i }
        }
        // Reach has to cover the fattest node the query could still touch.
        let reach = slop + maxRadiusWorld * 3
        if !grid.forEach(nearX: gx, y: gy, radius: reach, visit) {
            for i in 0..<n { visit(i) }
        }
        return best >= 0 ? best : nil
    }

    func setHover(_ index: Int?) {
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        hoverRevision &+= 1
    }

    func id(at index: Int) -> String? {
        data.ids.indices.contains(index) ? data.ids[index] : nil
    }

    func title(at index: Int) -> String? {
        data.titles.indices.contains(index) ? data.titles[index] : nil
    }

    // MARK: Pointer input

    /// Left button down: grab a node if one is under the pointer, else pan.
    func beginPrimaryDrag(at point: CGPoint) {
        lastDragPoint = point
        userAdjusted = true
        if let index = hitTest(viewPoint: point) {
            dragIndex = index
            pinned = index
            alphaTarget = 0.3
            reheat(to: 0.3)
        } else {
            panning = true
        }
    }

    func continuePrimaryDrag(to point: CGPoint) {
        defer { lastDragPoint = point }
        if let index = dragIndex {
            let target = viewToGraph(point)
            place(index, atProjected: target)
            vx[index] = 0
            vy[index] = 0
            vz[index] = 0
            projectionDirty = true
            gridDirty = true
            reheat(to: 0.3)
        } else if panning {
            panBy(CGSize(width: point.x - lastDragPoint.x, height: point.y - lastDragPoint.y))
        }
    }

    /// Puts a node under the pointer. In 3D the drag slides it across the
    /// camera plane at its own depth, which is the only unambiguous reading of
    /// a 2D gesture on a 3D scene.
    private func place(_ i: Int, atProjected p: CGPoint) {
        guard px.indices.contains(i) else { return }
        guard is3D else {
            px[i] = Double(p.x)
            py[i] = Double(p.y)
            return
        }
        let s = max(sd[i], 0.0001)
        let x1 = Double(p.x) / s
        let y2 = Double(p.y) / s
        let z2 = sz[i]
        let cy = cos(yaw), sw = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        let y = y2 * cp + z2 * sp
        let z1 = -y2 * sp + z2 * cp
        px[i] = x1 * cy - z1 * sw
        py[i] = y
        pz[i] = x1 * sw + z1 * cy
    }

    /// A release that never really moved is a click: open the note.
    func endPrimaryDrag(at point: CGPoint, moved: Bool) {
        if let index = dragIndex, !moved, let path = id(at: index) {
            onOpenNode?(path)
        }
        dragIndex = nil
        panning = false
        pinned = nil
        alphaTarget = 0
        setHover(hitTest(viewPoint: point))
    }

    var isDraggingNode: Bool { dragIndex != nil }

    func panBy(_ delta: CGSize) {
        guard delta != .zero else { return }
        userAdjusted = true
        pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
        cameraRevision &+= 1
    }

    /// Scale about a point in view space, so whatever is under the pointer stays put.
    func zoomBy(_ factor: CGFloat, around anchor: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let next = min(max(zoom * factor, 0.02), 8)
        guard next != zoom else { return }
        userAdjusted = true
        let before = viewToGraph(anchor)
        zoom = next
        pan = CGSize(
            width: anchor.x - before.x * next,
            height: anchor.y - before.y * next
        )
        cameraRevision &+= 1
        setHover(hitTest(viewPoint: anchor))
    }

    /// Frame the whole graph and hand the camera back to auto-framing.
    func fitToView() {
        fit(in: viewSize)
        userAdjusted = false
        needsFit = false
        cameraRevision &+= 1
    }

    func fit(in size: CGSize, slack: CGFloat = 1) {
        let n = nodeCount
        guard n > 0, size.width > 1, size.height > 1 else { return }
        if is3D { recenterCamera() }
        if projectionDirty { refreshProjection() }
        guard sx.count == n else { return }
        var minX = sx[0], maxX = sx[0], minY = sy[0], maxY = sy[0]
        for i in 1..<n {
            minX = min(minX, sx[i]); maxX = max(maxX, sx[i])
            minY = min(minY, sy[i]); maxY = max(maxY, sy[i])
        }
        let w = max(maxX - minX, 80) + 120
        let h = max(maxY - minY, 80) + 120
        let raw = min(size.width / w, size.height / h) / max(slack, 0.01)
        zoom = min(max(raw, 0.06), 1.3)
        pan = CGSize(
            width: size.width / 2 - (minX + maxX) / 2 * zoom,
            height: size.height / 2 - (minY + maxY) / 2 * zoom
        )
    }

    // MARK: Focus

    /// 1-hop neighbourhood of the selection. Cached: it only changes when the
    /// selection does, not when the nodes move.
    private func refreshFocus(selected: Int) {
        guard selected != focusKey || focusMask.count != nodeCount else { return }
        focusKey = selected
        if focusMask.count != nodeCount {
            focusMask = [Bool](repeating: false, count: nodeCount)
        } else {
            for i in 0..<nodeCount { focusMask[i] = false }
        }
        focusActive = selected >= 0 && selected < nodeCount
        guard focusActive else { return }
        focusMask[selected] = true
        for nb in adjacency.neighbours(of: selected) {
            let j = Int(nb)
            if j >= 0 && j < nodeCount { focusMask[j] = true }
        }
    }

    // MARK: Drawing

    /// Renders the whole graph in a handful of drawing calls. `tick` is unused
    /// beyond forcing SwiftUI to re-run this closure each animation frame.
    /// `matching`, when non-nil, is the set of node IDs a live search query
    /// hit — everything else fades instead of drawing at full strength.
    func draw(into screen: inout GraphicsContext, size: CGSize, selected: String?, matching: Set<String>?, tick: Date) {
        setViewSize(size)
        let n = nodeCount
        guard n > 0 else { return }
        if projectionDirty { refreshProjection() }
        if needsFit {
            fit(in: size, slack: pendingFitSlack)
            needsFit = false
        }
        let z = max(zoom, 0.0001)
        // `screen` stays untransformed for labels and the hover card; `ctx` is
        // the world.
        var ctx = screen
        ctx.translateBy(x: pan.width, y: pan.height)
        ctx.scaleBy(x: z, y: z)

        // Visible window in graph coordinates, with a margin for labels.
        let margin = 90 / z
        let minX = -pan.width / z - margin
        let minY = -pan.height / z - margin
        let maxX = (size.width - pan.width) / z + margin
        let maxY = (size.height - pan.height) / z + margin

        // Set equality short-circuits on identical storage, so this is free
        // frame to frame and only rebuilds when the query actually changes.
        if matching != lastMatching {
            lastMatching = matching
            matchIndex = matching.map { ids in Set(ids.compactMap { data.indexByID[$0] }) }
            matchRevision &+= 1
        }
        let matches = matchIndex
        let selectedIndex = selected.flatMap { data.indexByID[$0] } ?? -1
        var hovered = hoveredIndex ?? -1
        if hovered >= n { hovered = -1 }
        refreshFocus(selected: selectedIndex)

        func dimmed(_ i: Int) -> Bool {
            if let matches, !matches.contains(i) { return true }
            // Distance from the selection shades the *ego* view only — that is
            // what its outer ring is for. In the whole-vault view every note
            // stays at full brightness until a search narrows it; dimming
            // everything a hop away from the open note made the graph look
            // broken rather than focused.
            if scope == .local, focusActive, !focusMask[i] { return true }
            return false
        }

        // One Path, one stroke per opacity tier. Building and stroking a
        // separate Path per edge was what pinned a 20k-link vault at 100% CPU.
        var dimLinks = Path()
        var farLinks = Path()
        var links = Path()
        var hotLinks = Path()
        var drawn = 0
        let ea = data.edgeA, eb = data.edgeB
        for e in 0..<ea.count {
            let a = Int(ea[e]), b = Int(eb[e])
            let ax = sx[a], ay = sy[a], bx = sx[b], by = sy[b]
            if max(ax, bx) < minX || min(ax, bx) > maxX { continue }
            if max(ay, by) < minY || min(ay, by) > maxY { continue }
            let from = CGPoint(x: ax, y: ay)
            let to = CGPoint(x: bx, y: by)
            if a == selectedIndex || b == selectedIndex || a == hovered || b == hovered {
                hotLinks.move(to: from); hotLinks.addLine(to: to)
            } else if dimmed(a) && dimmed(b) {
                dimLinks.move(to: from); dimLinks.addLine(to: to)
            } else if is3D && (depthNorm(a) + depthNorm(b)) * 0.5 > 0.5 {
                farLinks.move(to: from); farLinks.addLine(to: to)
            } else {
                links.move(to: from); links.addLine(to: to)
            }
            drawn += 1
            if drawn >= Self.maxEdgesDrawn { break }
        }
        let hairline = max(0.35, 0.9 / z)
        if !dimLinks.isEmpty {
            ctx.stroke(dimLinks, with: .color(.secondary.opacity(0.08)), lineWidth: hairline)
        }
        if !farLinks.isEmpty {
            ctx.stroke(farLinks, with: .color(.secondary.opacity(0.12)), lineWidth: hairline)
        }
        if !links.isEmpty {
            ctx.stroke(links, with: .color(.secondary.opacity(0.28)), lineWidth: hairline)
        }

        // Depth tiers double as the painter sort: far dots are laid down first
        // and near ones cover them, without sorting n indices every frame.
        var dimDots = Path()
        var farDots = Path()
        var midDots = Path()
        var dots = Path()
        var highlight = Path()
        let floorR = Self.minScreenRadius / Double(z)
        for i in 0..<n {
            let x = sx[i], y = sy[i]
            if x < minX || x > maxX || y < minY || y > maxY { continue }
            let r = max(radius[i] * sd[i], floorR)
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            if i == selectedIndex {
                highlight.addEllipse(in: rect)
            } else if dimmed(i) {
                dimDots.addEllipse(in: rect)
            } else if is3D {
                let d = depthNorm(i)
                if d > 0.66 { farDots.addEllipse(in: rect) }
                else if d > 0.33 { midDots.addEllipse(in: rect) }
                else { dots.addEllipse(in: rect) }
            } else {
                dots.addEllipse(in: rect)
            }
        }
        // Recessive rather than invisible: at depth 2 the outer ring is dimmed
        // by the same tier, and it still has to read as part of the picture.
        if !dimDots.isEmpty { ctx.fill(dimDots, with: .color(.primary.opacity(0.20))) }
        if !farDots.isEmpty { ctx.fill(farDots, with: .color(.primary.opacity(0.30))) }
        if !midDots.isEmpty { ctx.fill(midDots, with: .color(.primary.opacity(0.58))) }
        if !dots.isEmpty { ctx.fill(dots, with: .color(.primary.opacity(0.88))) }
        if !hotLinks.isEmpty {
            ctx.stroke(
                hotLinks,
                with: .color(.accentColor.opacity(0.7)),
                lineWidth: max(0.8, 1.6 / z)
            )
        }
        if !highlight.isEmpty { ctx.fill(highlight, with: .color(.accentColor)) }

        if selectedIndex >= 0, selectedIndex < n {
            ring(selectedIndex, into: &ctx, z: z, width: max(0.8, 1.4 / z), opacity: 0.55)
        }
        if hovered >= 0, hovered != selectedIndex {
            ring(hovered, into: &ctx, z: z, width: max(0.8, 1.8 / z), opacity: 1)
        }

        drawLabels(
            into: &screen, size: size, tick: tick,
            selected: selectedIndex, hovered: hovered, matches: matches,
            dimmed: dimmed
        )
        drawHoverCard(into: &screen, size: size)
    }

    private func ring(
        _ i: Int, into ctx: inout GraphicsContext,
        z: CGFloat, width: CGFloat, opacity: Double
    ) {
        let r = max(radius[i] * sd[i], Self.minScreenRadius / Double(z)) + 3.5 / Double(z)
        ctx.stroke(
            Path(ellipseIn: CGRect(
                x: sx[i] - r, y: sy[i] - r, width: r * 2, height: r * 2
            )),
            with: .color(.accentColor.opacity(opacity)),
            lineWidth: width
        )
    }

    // MARK: Labels

    /// The inputs that change *which* labels fit. Node motion is deliberately
    /// not one of them - see the relayout cadence below.
    private struct LabelKey: Equatable {
        var pan = CGSize.zero
        var zoom: CGFloat = 0
        var selected = -2
        var hovered = -2
        var layout = -1
        var matches = -1
        var paused = false
        var yaw = 0.0
        var pitch = 0.0
        var distance = 0.0
        var threeD = false
    }

    /// Labels are drawn into the untransformed context at a constant point
    /// size. Drawn into the world context instead they scaled with zoom, which
    /// on a fitted large vault meant sub-point text - and the old blanket
    /// `labelZoomThreshold` then suppressed all of it anyway.
    private func drawLabels(
        into screen: inout GraphicsContext,
        size: CGSize,
        tick: Date,
        selected: Int,
        hovered: Int,
        matches: Set<Int>?,
        dimmed: (Int) -> Bool
    ) {
        let n = nodeCount
        guard n > 0 else { return }
        let key = LabelKey(
            pan: pan, zoom: zoom, selected: selected, hovered: hovered,
            layout: layoutGeneration, matches: matchRevision, paused: isPaused,
            yaw: yaw, pitch: pitch, distance: cameraDistance, threeD: is3D
        )
        let now = tick.timeIntervalSinceReferenceDate
        // Re-place when the camera or the selection moves, and otherwise only
        // on a slow cadence while the layout is still settling: recomputing
        // every frame makes the visible set strobe as nodes swap places.
        let drifted = !isPaused && (now - lastLabelLayout) > Self.labelRelayoutInterval
        if key != labelKey || drifted {
            labelKey = key
            lastLabelLayout = now
            placedLabels = placeLabels(
                into: screen, size: size,
                selected: selected, hovered: hovered, matches: matches
            )
        }

        let z = max(zoom, 0.0001)
        for i in placedLabels where i < n {
            let point = CGPoint(
                x: sx[i] * z + pan.width,
                y: sy[i] * z + pan.height + CGFloat(screenRadius(i)) + 3
            )
            let special = i == selected || i == hovered
            var opacity = dimmed(i) ? 0.34 : 0.92
            if is3D { opacity *= 1 - 0.5 * depthNorm(i) }
            screen.draw(
                Text(labelText[i])
                    .font(.system(size: Self.labelFontSize, weight: special ? .semibold : .regular))
                    .foregroundColor(special ? .primary : .primary.opacity(opacity)),
                at: point,
                anchor: .top
            )
        }
    }

    /// Greedy screen-space packing against a uniform occupancy grid, walked in
    /// priority order. Replaces the old "top 260 by degree, drawn blind", which
    /// piled every hub's label on top of its neighbours'.
    private func placeLabels(
        into ctx: GraphicsContext,
        size: CGSize,
        selected: Int,
        hovered: Int,
        matches: Set<Int>?
    ) -> [Int] {
        let n = nodeCount
        guard n > 0, size.width > 1, size.height > 1 else { return [] }
        let z = max(zoom, 0.0001)
        let cell: CGFloat = 26
        let cols = max(1, Int(size.width / cell) + 1)
        let rows = max(1, Int(size.height / cell) + 1)
        var buckets = [[Int32]](repeating: [], count: cols * rows)
        var rects: [CGRect] = []
        var placed: [Int] = []
        var measured = 0
        let limit = CGSize(width: 260, height: 40)

        func consider(_ i: Int) {
            guard placed.count < Self.maxLabelsPlaced, measured < Self.maxLabelCandidates else { return }
            let special = i == selected || i == hovered || (matches?.contains(i) ?? false)
            // Cheap rejects first: only survivors pay for a text measurement.
            let cx = sx[i] * z + pan.width
            let cy = sy[i] * z + pan.height
            guard cx > -140, cx < size.width + 140, cy > -40, cy < size.height + 40 else { return }
            if is3D, !special, depthNorm(i) > 0.6 { return }
            measured += 1

            let text = Text(labelText[i])
                .font(.system(size: Self.labelFontSize, weight: special ? .semibold : .regular))
            let measure = ctx.resolve(text).measure(in: limit)
            let top = cy + CGFloat(screenRadius(i)) + 3
            let rect = CGRect(
                x: cx - measure.width / 2, y: top,
                width: measure.width, height: measure.height
            ).insetBy(dx: -2, dy: -1)
            guard rect.maxY < size.height + 12, rect.minY > -12 else { return }

            let c0 = max(0, Int(rect.minX / cell)), c1 = min(cols - 1, Int(rect.maxX / cell))
            let r0 = max(0, Int(rect.minY / cell)), r1 = min(rows - 1, Int(rect.maxY / cell))
            guard c1 >= c0, r1 >= r0 else { return }
            for gy in r0...r1 {
                for gx in c0...c1 {
                    for k in buckets[gy * cols + gx] where rects[Int(k)].intersects(rect) { return }
                }
            }
            let slot = Int32(rects.count)
            rects.append(rect)
            for gy in r0...r1 {
                for gx in c0...c1 { buckets[gy * cols + gx].append(slot) }
            }
            placed.append(i)
        }

        var exhausted: Bool {
            placed.count >= Self.maxLabelsPlaced || measured >= Self.maxLabelCandidates
        }
        if selected >= 0, selected < n { consider(selected) }
        if hovered >= 0, hovered < n, hovered != selected { consider(hovered) }
        // Two passes so the selection's neighbourhood always wins its labels
        // before the rest of the graph competes for the same pixels.
        if focusActive {
            for i in labelOrder where i != selected && i != hovered && focusMask[i] {
                if exhausted { break }
                consider(i)
            }
        }
        for i in labelOrder where i != selected && i != hovered {
            if exhausted { break }
            if focusActive && focusMask[i] { continue }
            consider(i)
        }
        return placed
    }

    /// Identity card for the hovered node, drawn in screen space so it stays
    /// legible at any zoom.
    private func drawHoverCard(into ctx: inout GraphicsContext, size: CGSize) {
        guard let i = hoveredIndex, i < nodeCount, !isDraggingNode else { return }
        let folder = GraphScanner.parentPath(of: data.ids[i])
        // The vault-wide count, not the scoped one: in an ego graph the visible
        // edges are only part of the story.
        let links = Int(weight[i])
        var rows: [GraphicsContext.ResolvedText] = [
            ctx.resolve(Text(data.titles[i])
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary))
        ]
        if !folder.isEmpty {
            rows.append(ctx.resolve(Text(folder)
                .font(.system(size: 10))
                .foregroundColor(.secondary)))
        }
        rows.append(ctx.resolve(Text(links == 1 ? "1 link" : "\(links) links")
            .font(.system(size: 10))
            .foregroundColor(.secondary)))

        let limit = CGSize(width: 280, height: 40)
        let sizes = rows.map { $0.measure(in: limit) }
        let padding: CGFloat = 8
        let spacing: CGFloat = 2
        let cardWidth = (sizes.map(\.width).max() ?? 0) + padding * 2
        let cardHeight = sizes.reduce(0) { $0 + $1.height }
            + spacing * CGFloat(max(0, rows.count - 1)) + padding * 2

        // Sit below-right of the node, flipping in whenever the edge is close.
        let anchor = viewPoint(of: i)
        let gap = CGFloat(screenRadius(i)) + 10
        var origin = CGPoint(x: anchor.x + gap, y: anchor.y + gap)
        if origin.x + cardWidth > size.width - 6 { origin.x = anchor.x - gap - cardWidth }
        if origin.y + cardHeight > size.height - 6 { origin.y = anchor.y - gap - cardHeight }
        origin.x = min(max(origin.x, 6), max(6, size.width - cardWidth - 6))
        origin.y = min(max(origin.y, 6), max(6, size.height - cardHeight - 6))

        let card = Path(
            roundedRect: CGRect(origin: origin, size: CGSize(width: cardWidth, height: cardHeight)),
            cornerRadius: 7,
            style: .continuous
        )
        ctx.fill(card, with: .color(.black.opacity(0.55)))
        ctx.stroke(card, with: .color(.white.opacity(0.16)), lineWidth: 1)

        var y = origin.y + padding
        for (row, rowSize) in zip(rows, sizes) {
            ctx.draw(row, at: CGPoint(x: origin.x + padding, y: y), anchor: .topLeading)
            y += rowSize.height + spacing
        }
    }
}

// MARK: - Barnes-Hut octree

/// Flat-array octree, reused across frames so a step allocates nothing. The
/// quadrant bit trick just gains a z bit; centre-of-mass and the theta test are
/// unchanged. A 2D layout leaves every z at zero and simply never populates the
/// far half, which keeps one implementation for both modes.
private struct BHTree {
    private var comX: [Double] = []
    private var comY: [Double] = []
    private var comZ: [Double] = []
    private var mass: [Double] = []
    private var kids: [Int32] = []       // eight slots per node, -1 when empty
    private var branch: [Bool] = []      // true once this node has any child
    private var leaf: [Int32] = []       // body index, or -1
    private var boxX: [Double] = []
    private var boxY: [Double] = []
    private var boxZ: [Double] = []
    private var half: [Double] = []
    private static let maxDepth = 26
    private static let emptyKids: [Int32] = [-1, -1, -1, -1, -1, -1, -1, -1]

    mutating func reset(
        centerX: Double, centerY: Double, centerZ: Double,
        half h: Double, capacity: Int
    ) {
        let slots = max(8, capacity * 2)
        comX.removeAll(keepingCapacity: true); comX.reserveCapacity(slots)
        comY.removeAll(keepingCapacity: true); comY.reserveCapacity(slots)
        comZ.removeAll(keepingCapacity: true); comZ.reserveCapacity(slots)
        mass.removeAll(keepingCapacity: true); mass.reserveCapacity(slots)
        kids.removeAll(keepingCapacity: true); kids.reserveCapacity(slots * 8)
        branch.removeAll(keepingCapacity: true); branch.reserveCapacity(slots)
        leaf.removeAll(keepingCapacity: true); leaf.reserveCapacity(slots)
        boxX.removeAll(keepingCapacity: true); boxX.reserveCapacity(slots)
        boxY.removeAll(keepingCapacity: true); boxY.reserveCapacity(slots)
        boxZ.removeAll(keepingCapacity: true); boxZ.reserveCapacity(slots)
        self.half.removeAll(keepingCapacity: true); self.half.reserveCapacity(slots)
        addNode(centerX, centerY, centerZ, h)
    }

    @discardableResult
    private mutating func addNode(_ x: Double, _ y: Double, _ z: Double, _ h: Double) -> Int32 {
        let index = Int32(mass.count)
        comX.append(0); comY.append(0); comZ.append(0); mass.append(0)
        kids.append(contentsOf: Self.emptyKids)
        branch.append(false)
        leaf.append(-1)
        boxX.append(x); boxY.append(y); boxZ.append(z); half.append(h)
        return index
    }

    private func octant(_ node: Int, _ x: Double, _ y: Double, _ z: Double) -> Int {
        (x < boxX[node] ? 0 : 1) | (y < boxY[node] ? 0 : 2) | (z < boxZ[node] ? 0 : 4)
    }

    private mutating func child(of node: Int, octant q: Int) -> Int32 {
        if kids[node * 8 + q] >= 0 { return kids[node * 8 + q] }
        let h = half[node] * 0.5
        let cx = boxX[node] + (q & 1 == 0 ? -h : h)
        let cy = boxY[node] + (q & 2 == 0 ? -h : h)
        let cz = boxZ[node] + (q & 4 == 0 ? -h : h)
        let created = addNode(cx, cy, cz, h)
        kids[node * 8 + q] = created
        branch[node] = true
        return created
    }

    mutating func insert(body: Int32, x: Double, y: Double, z: Double) {
        var node = 0
        var depth = 0
        while true {
            if mass[node] == 0 {
                mass[node] = 1
                comX[node] = x; comY[node] = y; comZ[node] = z
                leaf[node] = body
                return
            }
            // Coincident or near-coincident points would subdivide forever;
            // past the depth cap the node just becomes a weighted bucket.
            if depth >= Self.maxDepth {
                let m = mass[node] + 1
                comX[node] = (comX[node] * mass[node] + x) / m
                comY[node] = (comY[node] * mass[node] + y) / m
                comZ[node] = (comZ[node] * mass[node] + z) / m
                mass[node] = m
                leaf[node] = -1
                return
            }
            if leaf[node] >= 0 {
                let old = leaf[node]
                let ox = comX[node], oy = comY[node], oz = comZ[node]
                leaf[node] = -1
                let slot = Int(child(of: node, octant: octant(node, ox, oy, oz)))
                mass[slot] = 1
                comX[slot] = ox; comY[slot] = oy; comZ[slot] = oz
                leaf[slot] = old
            }
            let m = mass[node] + 1
            comX[node] = (comX[node] * mass[node] + x) / m
            comY[node] = (comY[node] * mass[node] + y) / m
            comZ[node] = (comZ[node] * mass[node] + z) / m
            mass[node] = m
            node = Int(child(of: node, octant: octant(node, x, y, z)))
            depth += 1
        }
    }

    /// Walks the tree for one body, calling `apply(dx, dy, dz, distance², mass)`
    /// once per cell that is far enough away to treat as a point.
    func accumulate(
        x: Double,
        y: Double,
        z: Double,
        body: Int32,
        theta2: Double,
        stack: inout [Int32],
        apply: (Double, Double, Double, Double, Double) -> Void
    ) {
        stack.removeAll(keepingCapacity: true)
        stack.append(0)
        while let raw = stack.popLast() {
            let node = Int(raw)
            let m = mass[node]
            if m == 0 { continue }
            if leaf[node] == body { continue }
            let dx = comX[node] - x
            let dy = comY[node] - y
            let dz = comZ[node] - z
            var d2 = dx * dx + dy * dy + dz * dz
            let width = half[node] * 2
            if !branch[node] || width * width < theta2 * d2 {
                if d2 < 4 { d2 = 4 }
                apply(dx, dy, dz, d2, m)
            } else {
                for q in 0..<8 where kids[node * 8 + q] >= 0 {
                    stack.append(kids[node * 8 + q])
                }
            }
        }
    }
}

// MARK: - Spatial hash

/// Uniform grid over the projected positions, rebuilt lazily. A settled graph
/// builds it once and every subsequent hover query is a handful of cells, where
/// the old hit test was a full linear scan per `mouseMoved` - at ~100 Hz.
private struct SpatialGrid {
    private var originX = 0.0
    private var originY = 0.0
    private var cell = 1.0
    private var cols = 0
    private var rows = 0
    private var start: [Int32] = []
    private var items: [Int32] = []

    mutating func build(x: [Double], y: [Double], count n: Int) {
        cols = 0
        rows = 0
        start.removeAll(keepingCapacity: true)
        items.removeAll(keepingCapacity: true)
        guard n > 0, x.count >= n, y.count >= n else { return }
        var minX = x[0], maxX = x[0], minY = y[0], maxY = y[0]
        for i in 1..<n {
            minX = min(minX, x[i]); maxX = max(maxX, x[i])
            minY = min(minY, y[i]); maxY = max(maxY, y[i])
        }
        let spanX = max(maxX - minX, 1)
        let spanY = max(maxY - minY, 1)
        // Roughly sqrt(n) cells per axis: a constant handful of nodes per cell.
        let target = max(4.0, Double(n).squareRoot())
        cell = max(max(spanX, spanY) / target, 1e-6)
        cols = max(1, min(1024, Int(spanX / cell) + 1))
        rows = max(1, min(1024, Int(spanY / cell) + 1))
        originX = minX
        originY = minY

        let buckets = cols * rows
        start = [Int32](repeating: 0, count: buckets + 1)
        for i in 0..<n { start[index(x[i], y[i]) + 1] += 1 }
        for b in 1...buckets { start[b] += start[b - 1] }
        items = [Int32](repeating: 0, count: n)
        var cursor = start
        for i in 0..<n {
            let b = index(x[i], y[i])
            items[Int(cursor[b])] = Int32(i)
            cursor[b] += 1
        }
    }

    private func index(_ x: Double, _ y: Double) -> Int {
        let cx = min(max(Int((x - originX) / cell), 0), cols - 1)
        let cy = min(max(Int((y - originY) / cell), 0), rows - 1)
        return cy * cols + cx
    }

    /// Visits every node in the cells covering `radius` around the point.
    /// Returns false when the query would sweep most of the grid, so the caller
    /// can fall back to a straight scan rather than walk it the long way.
    func forEach(nearX x: Double, y: Double, radius: Double, _ visit: (Int) -> Void) -> Bool {
        guard cols > 0, rows > 0, start.count == cols * rows + 1 else { return false }
        let c0 = min(max(Int((x - radius - originX) / cell), 0), cols - 1)
        let c1 = min(max(Int((x + radius - originX) / cell), 0), cols - 1)
        let r0 = min(max(Int((y - radius - originY) / cell), 0), rows - 1)
        let r1 = min(max(Int((y + radius - originY) / cell), 0), rows - 1)
        guard c1 >= c0, r1 >= r0, (c1 - c0 + 1) * (r1 - r0 + 1) <= 4096 else { return false }
        for gy in r0...r1 {
            let row = gy * cols
            for gx in c0...c1 {
                let b = row + gx
                for k in Int(start[b])..<Int(start[b + 1]) { visit(Int(items[k])) }
            }
        }
        return true
    }
}
