import SwiftUI
import AppKit

/// Content of one main (sidebar + editor) window. Owns a fresh `WindowState`
/// per instance, so every window navigates, selects, and searches on its
/// own — only the underlying vault data in `VaultManager` is shared.
struct MainWindowView: View {
    @ObservedObject var vaultManager: VaultManager
    @ObservedObject var server: NoteServer
    @ObservedObject private var menuBar = MenuBarController.shared
    @ObservedObject private var settingsStore = SettingsStore.shared
    @StateObject private var windowState: WindowState
    /// Whether this instance is a popped-out single-note window rather than
    /// the app's real main window — both are the same view, but only the
    /// real one should be tagged `.blackGlassMainWindow` (see
    /// `MenuBarController.reallyShowMainWindow()`, which looks for that tag
    /// specifically so it doesn't surface/reuse a note pop-out instead).
    private let isPopOut: Bool

    /// `initialSelection`/`sidebarVisible` matter only for a popped-out note
    /// window: it's this same view, just pre-selecting one note and — per
    /// Settings — usually starting with the sidebar hidden, since a
    /// pop-out's whole point is a focused, single-note window.
    init(vaultManager: VaultManager, server: NoteServer, initialSelection: FileItem? = nil, sidebarVisible: Bool = true) {
        self.vaultManager = vaultManager
        self.server = server
        self.isPopOut = initialSelection != nil
        let state = WindowState()
        state.sidebarVisible = sidebarVisible
        if let initialSelection { state.select(initialSelection) }
        _windowState = StateObject(wrappedValue: state)
    }

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .contentBackground)
                .ignoresSafeArea()

            HSplitView {
                if windowState.sidebarVisible {
                    SidebarView(vaultManager: vaultManager, windowState: windowState)
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                        .frame(maxHeight: .infinity)
                        .ignoresSafeArea(edges: .top)
                }

                // Its own column between the tree and the editor, so a note
                // stays open and readable while the graph is up.
                if windowState.showGraph {
                    GraphView(vaultManager: vaultManager, windowState: windowState)
                        .frame(minWidth: 260, idealWidth: 420, maxWidth: .infinity)
                        .frame(maxHeight: .infinity)
                        .ignoresSafeArea(edges: .top)
                }

                Group {
                    if let id = windowState.soleSelectedID,
                       let selected = vaultManager.findInTree(id: id), !selected.isDirectory {
                        EditorView(
                            vaultManager: vaultManager,
                            fileItem: selected,
                            sidebarVisible: $windowState.sidebarVisible,
                            onNavigate: { item in
                                let live = vaultManager.findInTree(id: item.id) ?? item
                                windowState.reveal(live, ancestorFolderIDs: vaultManager.ancestorFolderIDs(of: live.url))
                            }
                        ) { url, content in
                            vaultManager.noteContentDidChange(at: url, content: content)
                        }
                    } else {
                        emptyState
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .toolbar(.hidden, for: .automatic)
            .toolbar(.hidden, for: .windowToolbar)

            if windowState.showOmnibar {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { windowState.showOmnibar = false }

                OmnibarView(vaultManager: vaultManager, windowState: windowState, isPresented: $windowState.showOmnibar)
                    // A backdrop behind the panel's own translucent material,
                    // blurring the desktop rather than sampling the dimming
                    // scrim right behind it in this same window — without
                    // it, the material picks up the scrim and the omnibar
                    // itself reads as dimmed along with the rest of the window.
                    .background {
                        VisualEffectBlur(material: .hudWindow)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    // Outer margin goes here, after the backdrop, so the
                    // backdrop stays the exact size of the panel instead of
                    // painting a bright ring around it.
                    .padding()
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        // Anchored to the outer ZStack, not the HSplitView pane, since
        // HSplitView (an NSSplitView bridge) doesn't reliably report safe
        // area geometry to an overlay nested inside one of its panes — that
        // put the lights over the editor's body text instead of its toolbar
        // row whenever the sidebar was hidden.
        .overlay(alignment: .topLeading) {
            if !windowState.sidebarVisible {
                WindowTrafficLights()
                    .padding(.top, 11)
                    .padding(.leading, 16)
            }
        }
        .sheet(isPresented: $windowState.showManageVaults) {
            ManageVaultsView(vaultManager: vaultManager)
        }
        .preferredColorScheme(settingsStore.settings.appearance.preferredColorScheme)
        .sheet(isPresented: $windowState.showSettings) {
            SettingsView(settingsStore: settingsStore, server: server, vaultManager: vaultManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            // willClose fires while the window is still in NSApp.windows.
            DispatchQueue.main.async {
                guard !MenuBarController.shared.hasOpenWindow else { return }
                vaultManager.suspendIndexIfUnused(serverRunning: server.isRunning)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            vaultManager.resumeIndexIfSuspended()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.18), value: windowState.showOmnibar)
        .hidesTitlebarFill()
        .tagAsBlackGlassMainWindow(!isPopOut)
        .focusedSceneValue(\.windowState, windowState)
        .onAppear {
            settingsStore.settings.appearance.applyToApp()
            // No need to walk NSApp.windows and reconfigure every open
            // window's chrome here: each window's own WindowChromeInstaller
            // (installed by `.hidesTitlebarFill()` below) already reapplies
            // its chrome via `viewDidMoveToWindow`/`layout()`. Doing it again
            // for every window on every window's appearance was O(open
            // windows) of redundant work each time any one of them appeared.
            server.attach(vaultManager: vaultManager)
            // `openWindowAction` is set from `BlackGlassApp.body` instead of
            // here — this `.onAppear` never runs at all when the app
            // launches with zero windows restored, which would leave it
            // permanently unset for the rest of that launch.
            menuBar.start()
            // Guarded by `isRunning`: this fires on every window's appearance
            // now that there can be more than one, and NoteServer.start()
            // unconditionally tears down and rebinds the listener — opening a
            // second window was silently bouncing the whole embedded server.
            if !server.isRunning, settingsStore.settings.serverEnabled || settingsStore.settings.serverAutoStart {
                settingsStore.settings.serverEnabled = true
                server.start(
                    port: settingsStore.settings.serverPort,
                    localhostOnly: settingsStore.settings.serverLocalhostOnly
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SidebarToggle(sidebarVisible: $windowState.sidebarVisible)
                Spacer()
                    .systemTitlebarDoubleClick()
            }
            .padding(.leading, windowState.sidebarVisible ? 14 : 78)
            .padding(.trailing, 14)
            .frame(height: WindowChrome.titlebarRowHeight)
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                Image(systemName: selectedIsDirectory ? "folder" : "doc.text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(selectedIsDirectory
                     ? "Press ⌘N to add a note in this folder"
                     : "Select a note or press ⌘N to create one")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            VisualEffectBlur(material: .contentBackground)
                .ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .top)
    }

    private var selectedIsDirectory: Bool {
        guard let id = windowState.soleSelectedID else { return false }
        return vaultManager.findInTree(id: id)?.isDirectory ?? false
    }
}
