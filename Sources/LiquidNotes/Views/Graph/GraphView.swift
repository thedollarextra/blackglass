import SwiftUI

struct GraphView: View {
    @ObservedObject var vaultManager: VaultManager
    @ObservedObject var windowState: WindowState
    @StateObject private var engine = GraphEngine()
    @State private var searchMatches: Set<String>?
    @State private var matchTask: Task<Void, Never>?

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
                    .systemTitlebarDoubleClick()
                if engine.isBuilding {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Fit") { engine.fitToView() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Frame the whole graph (or double-tap the trackpad)")
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
        .onAppear {
            engine.onOpenNode = { path in
                guard let vault = vaultManager.activeVault else { return }
                let url = vault.url.appendingPathComponent(path)
                let item = FileItem(url: url, isDirectory: false)
                let live = vaultManager.findInTree(id: item.id) ?? item
                windowState.reveal(live, ancestorFolderIDs: vaultManager.ancestorFolderIDs(of: live.url))
                windowState.showGraph = false
            }
            // Stash every freshly-built graph so the *next* time Graph mode
            // opens on this vault (this window or another), `start()` below
            // can skip straight to it instead of re-walking the vault.
            engine.onBuilt = { data in
                guard let vault = vaultManager.activeVault else { return }
                vaultManager.cacheGraph(data, for: vault)
            }
            start()
            scheduleMatchUpdate()
        }
        .onDisappear { engine.stop() }
        .onChange(of: vaultManager.activeVault?.id) { _, _ in start() }
        .onChange(of: windowState.searchQuery) { _, _ in scheduleMatchUpdate() }
        .onChange(of: windowState.isSearching) { _, _ in scheduleMatchUpdate() }
        .onExitCommand { windowState.showGraph = false }
    }

    private var statusText: String {
        if engine.isBuilding {
            return engine.total > 0 ? "Building \(engine.scanned)/\(engine.total)…" : "Scanning…"
        }
        if let hovered = engine.hoveredIndex, let title = engine.title(at: hovered) {
            return title
        }
        if let searchMatches {
            return "\(searchMatches.count) of \(engine.nodeCount) notes match"
        }
        return "\(engine.nodeCount) notes · \(engine.edgeCount) links"
    }

    private func canvas(tick: Date) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            var ctx = context
            engine.draw(into: &ctx, size: size, selected: selectedRelPath, matching: searchMatches, tick: tick)
        }
        // Input sits above the canvas: hover, wheel zoom, middle-button pan and
        // trackpad gestures all need AppKit events.
        .overlay { GraphInputSurface(engine: engine) }
        .onChange(of: timelineKey(tick)) { _, _ in
            engine.step()
        }
        .onChange(of: engine.generation) { _, _ in
            engine.fitToView()
        }
        .overlay(alignment: .bottom) {
            if engine.nodeCount > 0 {
                Text("Scroll to zoom · pinch or two fingers to browse · middle-drag to pan · click a note to open it")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if engine.nodeCount == 0 && !engine.isBuilding {
                Text("No markdown notes found in this vault.")
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
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

    private func start() {
        guard let vault = vaultManager.activeVault else { return }
        engine.start(vault: vault.url, cached: vaultManager.cachedGraph(for: vault))
    }

    /// Debounced, mirroring the sidebar's own search: a big vault's index
    /// lookup is cheap, but there's no reason to redo it on every keystroke.
    private func scheduleMatchUpdate() {
        matchTask?.cancel()
        let query = windowState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard windowState.isSearching, !query.isEmpty, let vault = vaultManager.activeVault else {
            searchMatches = nil
            return
        }
        matchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let hits = await vaultManager.searchAsync(query: query, limit: 5000)
            guard !Task.isCancelled else { return }
            searchMatches = Set(hits.map { GraphScanner.relative($0.fileItem.url, vault: vault.url) })
        }
    }
}
