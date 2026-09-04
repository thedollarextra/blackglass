import SwiftUI

struct GraphView: View {
    @ObservedObject var vaultManager: VaultManager
    @ObservedObject var windowState: WindowState
    @StateObject private var engine = GraphEngine()
    @State private var dragIndex: Int?
    @State private var panning = false
    @State private var panAnchor: CGSize = .zero
    @State private var magnifyAnchor: CGFloat = 1
    /// Stops the camera from following the layout once the user takes over.
    @State private var userAdjusted = false
    @State private var canvasSize: CGSize = CGSize(width: 800, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SidebarToggle(sidebarVisible: $windowState.sidebarVisible)
                Text("Graph")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if engine.isBuilding {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Fit") { engine.fit(in: canvasSize) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Close") { windowState.showGraph = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, windowState.sidebarVisible ? 14 : 78)
            .padding(.trailing, 14)
            .frame(height: WindowChrome.titlebarRowHeight)
            .frame(maxWidth: .infinity)

            // The schedule stops firing once the layout settles, so an idle
            // graph costs nothing. Any interaction reheats it and it resumes.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: engine.isPaused)) { timeline in
                canvas(tick: timeline.date)
            }
            // Rebuild the schedule outright when the paused flag flips, rather
            // than trusting TimelineView to resubscribe in place.
            .id(engine.isPaused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            VisualEffectBlur(material: .contentBackground)
                .ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .top)
        .onAppear { start() }
        .onDisappear { engine.stop() }
        .onChange(of: vaultManager.activeVault?.id) { _, _ in start() }
        .onChange(of: engine.generation) { _, _ in
            // A fresh build (not a cache hit — that doesn't bump `generation`)
            // just landed; keep it around for the next time Graph mode opens.
            if let vault = vaultManager.activeVault {
                vaultManager.cacheGraph(engine.data, for: vault)
            }
        }
        .onExitCommand { windowState.showGraph = false }
    }

    private var statusText: String {
        if engine.isBuilding {
            return engine.total > 0 ? "Building \(engine.scanned)/\(engine.total)…" : "Scanning…"
        }
        return "\(engine.nodeCount) notes · \(engine.edgeCount) links"
    }

    private func canvas(tick: Date) -> some View {
        GeometryReader { geo in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                var ctx = context
                engine.draw(into: &ctx, size: size, selected: selectedRelPath, tick: tick)
            }
            .gesture(graphGesture(in: geo.size))
            .onAppear {
                canvasSize = geo.size
                engine.fit(in: geo.size)
            }
            .onChange(of: timelineKey(tick)) { _, _ in
                engine.step()
                // Keep the whole graph framed while it expands out of its
                // seeded positions, until the user pans, zooms, or drags.
                if !userAdjusted { engine.fit(in: geo.size) }
            }
            .onChange(of: geo.size) { _, size in
                canvasSize = size
            }
            .onChange(of: engine.generation) { _, _ in
                userAdjusted = false
                engine.fit(in: geo.size)
            }
            .overlay {
                if engine.nodeCount == 0 && !engine.isBuilding {
                    Text("No markdown notes found in this vault.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Steps the simulation from `onChange` rather than inside the draw closure,
    /// so publishing the settled flag never happens mid-render.
    private func timelineKey(_ date: Date) -> TimeInterval { date.timeIntervalSinceReferenceDate }

    private var selectedRelPath: String? {
        guard let id = windowState.soleSelectedID,
              let selected = vaultManager.findInTree(id: id),
              let vault = vaultManager.activeVault else { return nil }
        return GraphScanner.relative(selected.url, vault: vault.url)
    }

    private func graphGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragIndex == nil && !panning {
                    let start = engine.viewToGraph(value.startLocation)
                    if let index = engine.nodeIndex(near: start, within: 18 / max(engine.zoom, 0.2)) {
                        dragIndex = index
                        engine.beginDrag(index)
                        userAdjusted = true
                    } else {
                        panning = true
                        panAnchor = engine.pan
                        userAdjusted = true
                    }
                }
                if let index = dragIndex {
                    engine.dragNode(index, to: engine.viewToGraph(value.location))
                } else if panning {
                    engine.pan = CGSize(
                        width: panAnchor.width + value.translation.width,
                        height: panAnchor.height + value.translation.height
                    )
                }
            }
            .onEnded { value in
                if let index = dragIndex,
                   hypot(value.translation.width, value.translation.height) < 4,
                   let path = engine.id(at: index),
                   let vault = vaultManager.activeVault {
                    let url = vault.url.appendingPathComponent(path)
                    windowState.revealInTree(FileItem(url: url, isDirectory: false), in: vaultManager)
                    windowState.showGraph = false
                }
                engine.endDrag()
                dragIndex = nil
                panning = false
            }
            .simultaneously(with:
                MagnificationGesture()
                    .onChanged { value in
                        guard value > 0 else { return }
                        let factor = value / magnifyAnchor
                        magnifyAnchor = value
                        userAdjusted = true
                        engine.zoomBy(factor, around: CGPoint(x: size.width / 2, y: size.height / 2))
                    }
                    .onEnded { _ in magnifyAnchor = 1 }
            )
    }

    private func start() {
        guard let vault = vaultManager.activeVault else { return }
        if let cached = vaultManager.cachedGraph(for: vault) {
            engine.load(cached)
        } else {
            engine.start(vault: vault.url)
        }
    }
}
