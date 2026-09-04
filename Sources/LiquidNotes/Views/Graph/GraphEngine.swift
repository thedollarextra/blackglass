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

// MARK: - Layout

@MainActor
final class GraphEngine: ObservableObject {
    // Coarse UI state. Published, but only changes a handful of times per second.
    @Published private(set) var isBuilding = false
    @Published private(set) var scanned = 0
    @Published private(set) var total = 0
    @Published private(set) var nodeCount = 0
    @Published private(set) var edgeCount = 0
    /// The layout has come to rest; `TimelineView` stops ticking on this.
    @Published private(set) var isPaused = true
    /// Bumped when a freshly built graph lands, so the view knows to re-fit.
    @Published private(set) var generation = 0
    @Published var pan: CGSize = .zero
    @Published var zoom: CGFloat = 1

    // Hot layout state. Never published: it changes every frame, and pushing it
    // through Combine invalidated the whole view tree 24 times a second.
    private(set) var data = GraphData()
    private(set) var px: [Double] = []
    private(set) var py: [Double] = []
    private var vx: [Double] = []
    private var vy: [Double] = []
    private(set) var radius: [Double] = []
    /// Node indices by descending degree; label drawing walks the front of this.
    private(set) var labelOrder: [Int] = []

    private var alpha: Double = 0
    private var alphaTarget: Double = 0
    private var pinned: Int?
    private var tree = QuadTree()
    private var scratch: [Int32] = []
    private var visible: [Int] = []
    private var onScreen: Set<Int> = []
    private var task: Task<Void, Never>?

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
    private static let maxLabelsDrawn = 260
    private static let labelZoomThreshold: CGFloat = 0.5

    // MARK: Lifecycle

    func start(vault: URL) {
        task?.cancel()
        pan = .zero
        zoom = 1
        isBuilding = true
        scanned = 0
        total = 0
        load(GraphData())
        task = Task { [weak self] in
            let built = await GraphBuilder.build(vault: vault) { [weak self] done, count in
                Task { @MainActor in self?.report(scanned: done, total: count) }
            }
            guard let self, !Task.isCancelled else { return }
            self.load(built)
            self.isBuilding = false
            self.generation &+= 1
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

    /// Installs a freshly built graph and reseeds the layout.
    func load(_ next: GraphData) {
        data = next
        let n = next.nodeCount
        px = [Double](repeating: 0, count: n)
        py = [Double](repeating: 0, count: n)
        vx = [Double](repeating: 0, count: n)
        vy = [Double](repeating: 0, count: n)
        radius = [Double](repeating: 4, count: n)
        // Phyllotaxis seed: an even spread that gives the springs a head start.
        for i in 0..<n {
            let angle = Double(i) * 2.399963
            let r = 12 * (Double(i) + 1).squareRoot()
            px[i] = cos(angle) * r
            py[i] = sin(angle) * r
            radius[i] = 3.4 + min(7.0, Double(next.degree[i]).squareRoot() * 1.9)
        }
        labelOrder = (0..<n).sorted { next.degree[$0] > next.degree[$1] }
        scratch.reserveCapacity(64)
        nodeCount = n
        edgeCount = next.edgeCount
        pinned = nil
        alphaTarget = 0
        alpha = n > 1 ? 1 : 0
        isPaused = n <= 1
    }

    // MARK: Simulation

    func step() {
        let n = nodeCount
        guard n > 1 else { return }
        if alpha < Self.alphaMin && alphaTarget == 0 {
            if !isPaused { isPaused = true }
            return
        }
        alpha += (alphaTarget - alpha) * Self.alphaDecay
        applyRepulsion()
        applyLinks()
        integrate()
    }

    /// Barnes-Hut n-body repulsion. The previous version sampled every
    /// `n/220`th node pair and switched repulsion off entirely above 450 nodes,
    /// which collapsed larger vaults into a hairball.
    private func applyRepulsion() {
        let n = nodeCount
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for i in 0..<n {
            minX = min(minX, px[i]); maxX = max(maxX, px[i])
            minY = min(minY, py[i]); maxY = max(maxY, py[i])
        }
        let half = max(max(maxX - minX, maxY - minY) * 0.5, 1) * 1.02
        tree.reset(centerX: (minX + maxX) * 0.5, centerY: (minY + maxY) * 0.5, half: half, capacity: n)
        for i in 0..<n { tree.insert(body: Int32(i), x: px[i], y: py[i]) }

        let k = Self.repelStrength * alpha
        for i in 0..<n {
            var fx = 0.0, fy = 0.0
            tree.accumulate(
                x: px[i], y: py[i], body: Int32(i), theta2: Self.theta2, stack: &scratch
            ) { dx, dy, d2, mass in
                let w = k * mass / d2
                fx += dx * w
                fy += dy * w
            }
            vx[i] += fx
            vy[i] += fy
        }
    }

    private func applyLinks() {
        let a = data.edgeA, b = data.edgeB, degree = data.degree
        for e in 0..<a.count {
            let i = Int(a[e]), j = Int(b[e])
            var dx = px[j] - px[i]
            var dy = py[j] - py[i]
            var d2 = dx * dx + dy * dy
            if d2 < 0.0001 {
                dx = Double((e % 7) - 3) * 0.1 + 0.05
                dy = Double((e % 5) - 2) * 0.1 + 0.05
                d2 = dx * dx + dy * dy
            }
            let d = d2.squareRoot()
            // Weak links between hubs, so a heavily linked index note does not
            // drag the whole vault onto itself.
            let strength = Self.linkStrength / Double(max(1, min(degree[i], degree[j])))
            let force = (d - Self.linkDistance) * alpha * strength / d
            let bias = Double(degree[i]) / Double(max(1, degree[i] + degree[j]))
            vx[i] += dx * force * (1 - bias)
            vy[i] += dy * force * (1 - bias)
            vx[j] -= dx * force * bias
            vy[j] -= dy * force * bias
        }
    }

    private func integrate() {
        let n = nodeCount
        let g = Self.gravity * alpha
        let decay = Self.velocityDecay
        for i in 0..<n {
            if i == pinned {
                vx[i] = 0; vy[i] = 0
                continue
            }
            vx[i] -= px[i] * g
            vy[i] -= py[i] * g
            vx[i] *= decay
            vy[i] *= decay
            px[i] += vx[i]
            py[i] += vy[i]
        }
    }

    /// Nudge the layout back to life after an interaction.
    func reheat(to target: Double = 0.42) {
        alpha = max(alpha, target)
        if isPaused { isPaused = false }
    }

    // MARK: Interaction

    func viewToGraph(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.width) / zoom, y: (p.y - pan.height) / zoom)
    }

    func nodeIndex(near point: CGPoint, within distance: CGFloat) -> Int? {
        let x = Double(point.x), y = Double(point.y)
        var best = -1
        var bestD2 = Double(distance * distance)
        for i in 0..<nodeCount {
            let dx = px[i] - x, dy = py[i] - y
            let d2 = dx * dx + dy * dy
            if d2 < bestD2 { bestD2 = d2; best = i }
        }
        return best >= 0 ? best : nil
    }

    func id(at index: Int) -> String? {
        data.ids.indices.contains(index) ? data.ids[index] : nil
    }

    func beginDrag(_ index: Int) {
        pinned = index
        alphaTarget = 0.3
        reheat(to: 0.3)
    }

    func dragNode(_ index: Int, to point: CGPoint) {
        guard px.indices.contains(index) else { return }
        px[index] = Double(point.x)
        py[index] = Double(point.y)
        vx[index] = 0
        vy[index] = 0
        reheat(to: 0.3)
    }

    func endDrag() {
        pinned = nil
        alphaTarget = 0
    }

    /// Scale about a point in view space, so whatever is under the cursor stays put.
    func zoomBy(_ factor: CGFloat, around anchor: CGPoint) {
        let next = min(max(zoom * factor, 0.05), 6)
        guard next != zoom else { return }
        let before = viewToGraph(anchor)
        zoom = next
        pan = CGSize(
            width: anchor.x - before.x * next,
            height: anchor.y - before.y * next
        )
    }

    // MARK: Drawing

    /// Renders the whole graph in a handful of drawing calls. `tick` is unused
    /// beyond forcing SwiftUI to re-run this closure each animation frame.
    func draw(into ctx: inout GraphicsContext, size: CGSize, selected: String?, tick: Date) {
        _ = tick
        let n = nodeCount
        guard n > 0 else { return }
        let z = max(zoom, 0.0001)
        ctx.translateBy(x: pan.width, y: pan.height)
        ctx.scaleBy(x: z, y: z)

        // Visible window in graph coordinates, with a margin for labels.
        let margin = 60 / z
        let minX = -pan.width / z - margin
        let minY = -pan.height / z - margin
        let maxX = (size.width - pan.width) / z + margin
        let maxY = (size.height - pan.height) / z + margin

        // One Path, one stroke. Building and stroking a separate Path per edge
        // was what pinned a 20k-link vault at 100% CPU.
        var links = Path()
        var drawn = 0
        let ea = data.edgeA, eb = data.edgeB
        for e in 0..<ea.count {
            let a = Int(ea[e]), b = Int(eb[e])
            let ax = px[a], ay = py[a], bx = px[b], by = py[b]
            if max(ax, bx) < minX || min(ax, bx) > maxX { continue }
            if max(ay, by) < minY || min(ay, by) > maxY { continue }
            links.move(to: CGPoint(x: ax, y: ay))
            links.addLine(to: CGPoint(x: bx, y: by))
            drawn += 1
            if drawn >= Self.maxEdgesDrawn { break }
        }
        if drawn > 0 {
            ctx.stroke(
                links,
                with: .color(.secondary.opacity(0.28)),
                lineWidth: max(0.35, 0.9 / z)
            )
        }

        visible.removeAll(keepingCapacity: true)
        var dots = Path()
        var highlight = Path()
        let selectedIndex = selected.flatMap { data.indexByID[$0] } ?? -1
        for i in 0..<n {
            let x = px[i], y = py[i]
            if x < minX || x > maxX || y < minY || y > maxY { continue }
            visible.append(i)
            let r = radius[i]
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            if i == selectedIndex {
                highlight.addEllipse(in: rect)
            } else {
                dots.addEllipse(in: rect)
            }
        }
        if !dots.isEmpty {
            ctx.fill(dots, with: .color(.primary.opacity(0.85)))
        }
        if !highlight.isEmpty {
            ctx.fill(highlight, with: .color(.accentColor))
        }

        // Text is by far the most expensive thing a Canvas can draw, so labels
        // are capped and shown highest-degree first once zoomed in far enough.
        guard z >= Self.labelZoomThreshold, !visible.isEmpty else { return }
        onScreen.removeAll(keepingCapacity: true)
        for i in visible { onScreen.insert(i) }
        var budget = Self.maxLabelsDrawn
        for i in labelOrder {
            guard budget > 0 else { break }
            guard onScreen.contains(i) else { continue }
            budget -= 1
            ctx.draw(
                Text(data.titles[i])
                    .font(.system(size: 10, weight: i == selectedIndex ? .semibold : .regular))
                    .foregroundColor(.primary.opacity(0.92)),
                at: CGPoint(x: px[i], y: py[i] + radius[i] + 7)
            )
        }
    }

    func fit(in size: CGSize) {
        let n = nodeCount
        guard n > 0, size.width > 1, size.height > 1 else { return }
        var minX = px[0], maxX = px[0], minY = py[0], maxY = py[0]
        for i in 1..<n {
            minX = min(minX, px[i]); maxX = max(maxX, px[i])
            minY = min(minY, py[i]); maxY = max(maxY, py[i])
        }
        let w = max(maxX - minX, 80) + 120
        let h = max(maxY - minY, 80) + 120
        zoom = min(max(min(size.width / w, size.height / h), 0.06), 1.3)
        pan = CGSize(
            width: size.width / 2 - (minX + maxX) / 2 * zoom,
            height: size.height / 2 - (minY + maxY) / 2 * zoom
        )
    }
}

// MARK: - Barnes-Hut quadtree

/// Flat-array quadtree, reused across frames so a step allocates nothing.
private struct QuadTree {
    private var comX: [Double] = []
    private var comY: [Double] = []
    private var mass: [Double] = []
    private var kids: [Int32] = []       // four slots per node, -1 when empty
    private var leaf: [Int32] = []       // body index, or -1
    private var boxX: [Double] = []
    private var boxY: [Double] = []
    private var half: [Double] = []
    private static let maxDepth = 26

    mutating func reset(centerX: Double, centerY: Double, half h: Double, capacity: Int) {
        let slots = max(8, capacity * 2)
        comX.removeAll(keepingCapacity: true); comX.reserveCapacity(slots)
        comY.removeAll(keepingCapacity: true); comY.reserveCapacity(slots)
        mass.removeAll(keepingCapacity: true); mass.reserveCapacity(slots)
        kids.removeAll(keepingCapacity: true); kids.reserveCapacity(slots * 4)
        leaf.removeAll(keepingCapacity: true); leaf.reserveCapacity(slots)
        boxX.removeAll(keepingCapacity: true); boxX.reserveCapacity(slots)
        boxY.removeAll(keepingCapacity: true); boxY.reserveCapacity(slots)
        self.half.removeAll(keepingCapacity: true); self.half.reserveCapacity(slots)
        addNode(centerX, centerY, h)
    }

    @discardableResult
    private mutating func addNode(_ x: Double, _ y: Double, _ h: Double) -> Int32 {
        let index = Int32(mass.count)
        comX.append(0); comY.append(0); mass.append(0)
        kids.append(contentsOf: [-1, -1, -1, -1])
        leaf.append(-1)
        boxX.append(x); boxY.append(y); half.append(h)
        return index
    }

    private mutating func child(of node: Int, quadrant q: Int) -> Int32 {
        if kids[node * 4 + q] >= 0 { return kids[node * 4 + q] }
        let h = half[node] * 0.5
        let cx = boxX[node] + (q & 1 == 0 ? -h : h)
        let cy = boxY[node] + (q & 2 == 0 ? -h : h)
        let created = addNode(cx, cy, h)
        kids[node * 4 + q] = created
        return created
    }

    mutating func insert(body: Int32, x: Double, y: Double) {
        var node = 0
        var depth = 0
        while true {
            if mass[node] == 0 {
                mass[node] = 1; comX[node] = x; comY[node] = y; leaf[node] = body
                return
            }
            // Coincident or near-coincident points would subdivide forever;
            // past the depth cap the node just becomes a weighted bucket.
            if depth >= Self.maxDepth {
                let m = mass[node] + 1
                comX[node] = (comX[node] * mass[node] + x) / m
                comY[node] = (comY[node] * mass[node] + y) / m
                mass[node] = m
                leaf[node] = -1
                return
            }
            if leaf[node] >= 0 {
                let old = leaf[node]
                let ox = comX[node], oy = comY[node]
                leaf[node] = -1
                let q = (ox < boxX[node] ? 0 : 1) | (oy < boxY[node] ? 0 : 2)
                let slot = Int(child(of: node, quadrant: q))
                mass[slot] = 1; comX[slot] = ox; comY[slot] = oy; leaf[slot] = old
            }
            let m = mass[node] + 1
            comX[node] = (comX[node] * mass[node] + x) / m
            comY[node] = (comY[node] * mass[node] + y) / m
            mass[node] = m
            let q = (x < boxX[node] ? 0 : 1) | (y < boxY[node] ? 0 : 2)
            node = Int(child(of: node, quadrant: q))
            depth += 1
        }
    }

    /// Walks the tree for one body, calling `apply(dx, dy, distance², mass)`
    /// once per cell that is far enough away to treat as a point.
    func accumulate(
        x: Double,
        y: Double,
        body: Int32,
        theta2: Double,
        stack: inout [Int32],
        apply: (Double, Double, Double, Double) -> Void
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
            var d2 = dx * dx + dy * dy
            let width = half[node] * 2
            let isLeaf = kids[node * 4] < 0 && kids[node * 4 + 1] < 0
                && kids[node * 4 + 2] < 0 && kids[node * 4 + 3] < 0
            if isLeaf || width * width < theta2 * d2 {
                if d2 < 4 { d2 = 4 }
                apply(dx, dy, d2, m)
            } else {
                for q in 0..<4 where kids[node * 4 + q] >= 0 {
                    stack.append(kids[node * 4 + q])
                }
            }
        }
    }
}
