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
                scopeControls
                Button {
                    engine.setThreeD(!engine.is3D)
                } label: {
                    Image(systemName: "cube")
                }
                .buttonStyle(.plain)
                .foregroundStyle(engine.is3D ? Color.accentColor : Color.secondary)
                .help(engine.is3D ? "Back to a flat layout" : "3D layout — shift-drag or two fingers to orbit")
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
                // The graph stays up: it's its own pane now, so the note opens
                // beside it. Closing on every click made sense only back when
                // the graph took over the editor's space.
            }
            // Stash every freshly-built graph so the *next* time Graph mode
            // opens on this vault (this window or another), `start()` below
            // can skip straight to it instead of re-walking the vault.
            engine.onBuilt = { data in
                guard let vault = vaultManager.activeVault else { return }
                vaultManager.cacheGraph(data, for: vault)
            }
            // Set before the graph lands, so the first scoping already knows
            // which note the local view is centred on.
            engine.setFocus(selectedRelPath)
            start()
            scheduleMatchUpdate()
        }
        .onDisappear { engine.stop() }
        .onChange(of: vaultManager.activeVault?.id) { _, _ in start() }
        .onChange(of: selectedRelPath) { _, next in engine.setFocus(next) }
        .onChange(of: windowState.searchQuery) { _, _ in scheduleMatchUpdate() }
        .onChange(of: windowState.isSearching) { _, _ in scheduleMatchUpdate() }
        .onChange(of: windowState.omnibarQuery) { _, _ in scheduleMatchUpdate() }
        .onChange(of: windowState.showOmnibar) { _, _ in scheduleMatchUpdate() }
        .onExitCommand { windowState.showGraph = false }
    }

    /// Local/global scoping. The whole point of the graph is the neighbourhood
    /// around what you are reading; the whole vault at once is a screensaver.
    @ViewBuilder
    private var scopeControls: some View {
        Button {
            engine.setScope(engine.scope == .local ? .global : .local)
        } label: {
            Image(systemName: engine.scope == .local ? "scope" : "globe")
        }
        .buttonStyle(.plain)
        .foregroundStyle(engine.scope == .local ? Color.accentColor : Color.secondary)
        .help(engine.scope == .local
            ? "Showing the selected note's neighbourhood — switch to the whole vault"
            : "Showing the whole vault — switch to the selected note's neighbourhood")

        if engine.scope == .local {
            HStack(spacing: 4) {
                Button { engine.setLocalDepth(engine.localDepth - 1) } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.plain)
                .disabled(engine.localDepth <= 1)
                Text("\(engine.localDepth)")
                    .monospacedDigit()
                Button { engine.setLocalDepth(engine.localDepth + 1) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .disabled(engine.localDepth >= 3)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Hops out from the selected note")
        } else {
            // Two distinct glyphs rather than one recoloured: which of the
            // two states you are in has to read at a glance, and an accent
            // tint alone doesn't say whether notes are being hidden.
            Button {
                engine.setShowOrphans(!engine.showOrphans)
            } label: {
                Image(systemName: engine.showOrphans
                    ? "circle.dotted"
                    : "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.plain)
            .foregroundStyle(engine.showOrphans ? Color.secondary : Color.accentColor)
            .help(engine.showOrphans
                ? "Showing every note, unlinked ones as islands — show only connected notes"
                : "Showing only connected notes — show every note")
        }
    }

    private var statusText: String {
        if engine.isBuilding {
            return engine.total > 0 ? "Building \(engine.scanned)/\(engine.total)…" : "Scanning…"
        }
        if let hovered = engine.hoveredIndex, let title = engine.title(at: hovered) {
            return title
        }
        if let searchMatches {
            return "\(searchMatches.count) of \(engine.sourceNodeCount) notes match"
        }
        var parts = ["\(engine.nodeCount) notes", "\(engine.edgeCount) links"]
        // Only meaningful for the whole-vault view; in an ego graph "hidden"
        // would just be "the rest of the vault", which is the point of it.
        if engine.scope == .global, engine.hiddenCount > 0 {
            parts.append("\(engine.hiddenCount) unlinked")
        }
        return parts.joined(separator: " · ")
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
        .overlay(alignment: .bottom) {
            if engine.nodeCount > 0 {
                Text(hintText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if engine.nodeCount == 0 && !engine.isBuilding {
                Text(emptyText)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    private var hintText: String {
        engine.is3D
            ? "Shift-drag or two fingers to orbit · pinch to move closer · click a note to open it"
            : "Scroll to zoom · pinch or two fingers to browse · middle-drag to pan · click a note to open it"
    }

    private var emptyText: String {
        if engine.sourceNodeCount == 0 {
            return "No markdown notes found in this vault."
        }
        if engine.scope == .local {
            return engine.focusID == nil
                ? "Select a note to see its neighbourhood, or switch to the whole vault."
                : "That note isn't in the graph yet."
        }
        return "No linked notes. Show unlinked notes to see the rest of the vault."
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
        // Either search dims the graph — whichever one is currently open.
        let raw = windowState.showOmnibar
            ? windowState.omnibarQuery
            : (windowState.isSearching ? windowState.searchQuery : "")
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let vault = vaultManager.activeVault else {
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
