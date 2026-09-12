import SwiftUI
import AppKit

public enum EditorMode: String, CaseIterable, Identifiable {
    case uncooked
    case cooked

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .uncooked: return "Uncooked"
        case .cooked: return "Cooked"
        }
    }

    public var helpText: String {
        switch self {
        case .uncooked:
            return "Uncooked — raw text. Click the egg to cook (⌘E)"
        case .cooked:
            return "Cooked — rendered. Click the egg to uncook (⌘E)"
        }
    }

    public mutating func toggle() {
        self = self == .uncooked ? .cooked : .uncooked
    }
}

public struct EditorView: View {
    @ObservedObject var vaultManager: VaultManager
    let fileItem: FileItem
    @Binding var sidebarVisible: Bool
    /// False in a popped-out note window, which has no sidebar to toggle.
    var showSidebarToggle: Bool = true
    /// False inside the popped-out window itself, so it can't pop out again.
    var showPopOutButton: Bool = true
    var onNavigate: (FileItem) -> Void = { _ in }
    var onContentSaved: ((URL, String) -> Void)? = nil
    @ObservedObject private var settingsStore = SettingsStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var text: String = ""
    @State private var mode: EditorMode = .uncooked
    @State private var saveTask: Task<Void, Never>?
    @State private var lastSaved: String = ""
    @State private var requestFocusAtStart = false

    /// Renaming the open note from its own heading. Deliberately not routed
    /// through the sidebar's `renamingID`: that drives the tree's inline
    /// field, and having both open at once would be two editors of one name.
    @State private var isRenamingTitle = false
    @State private var titleDraft = ""

    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findMatchCount = 0
    @State private var findCurrentMatch = 0
    @FocusState private var isFindFieldFocused: Bool

    private var themeClass: String {
        switch settingsStore.settings.appearance {
        case .light: "theme-light"
        case .dark: "theme-dark"
        case .system: "theme-system"
        }
    }

    private func finishTitleRename(focusEditor: Bool) {
        guard isRenamingTitle else { return }
        isRenamingTitle = false
        let renamed = vaultManager.commitRename(fileItem, to: titleDraft, focusEditor: focusEditor)
        // The file moved, so the selection driving this view still names the
        // old path. `onNavigate` is what the sidebar's rename does by way of
        // `windowState.remap`, and it also re-reveals the row in the tree.
        if renamed.id != fileItem.id { onNavigate(renamed) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if showSidebarToggle {
                    SidebarToggle(sidebarVisible: $sidebarVisible)
                }
                if isRenamingTitle {
                    InlineRenameField(
                        text: $titleDraft,
                        font: .boldSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize),
                        onCommit: { focusEditor in finishTitleRename(focusEditor: focusEditor) },
                        onCancel: { isRenamingTitle = false }
                    )
                    .frame(maxWidth: 420)
                    .blocksWindowDrag()
                } else {
                    Text(fileItem.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .help("\(fileItem.url.path)\n\nDouble-click to rename")
                        // Without this the heading is window-drag background,
                        // and the second click of a double-click is taken by
                        // the titlebar (zoom/minimise) before SwiftUI sees it.
                        .blocksWindowDrag()
                        .onTapGesture(count: 2) {
                            titleDraft = fileItem.displayTitle
                            isRenamingTitle = true
                        }
                }

                Spacer(minLength: 8)
                    .systemTitlebarDoubleClick()

                if showPopOutButton {
                    Button {
                        openWindow(value: fileItem.url)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open in New Window")
                    .accessibilityLabel("Open in New Window")
                }

                EggModeToggle(mode: $mode)
            }
            .padding(.leading, sidebarVisible ? 14 : 78)
            .padding(.trailing, 14)
            .frame(height: WindowChrome.titlebarRowHeight)
            .frame(maxWidth: .infinity)

            Group {
                if mode == .uncooked {
                    FindableTextView(
                        text: $text,
                        searchQuery: showFind ? findQuery : "",
                        matchCount: $findMatchCount,
                        currentMatch: $findCurrentMatch,
                        requestFocusAtStart: $requestFocusAtStart,
                        onTextChange: queueAutoSave
                    )
                    .overlay(alignment: .topTrailing) {
                        if showFind {
                            FindBar(
                                query: $findQuery,
                                matchCount: findMatchCount,
                                currentMatch: $findCurrentMatch,
                                onClose: { showFind = false },
                                isFocused: $isFindFieldFocused
                            )
                            .padding(.top, 10)
                            .padding(.trailing, 14)
                        }
                    }
                } else {
                    CookedNoteView(
                        markdown: text,
                        fileItem: fileItem,
                        vaultManager: vaultManager,
                        themeClass: themeClass,
                        onNavigate: onNavigate
                    )
                    .padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            VisualEffectBlur(material: .contentBackground)
                .ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .top)
        .onAppear { loadContent() }
        .onChange(of: fileItem.id) { _, _ in
            flushSave()
            loadContent()
        }
        .onDisappear { flushSave() }
        .onReceive(NotificationCenter.default.publisher(for: .blackGlassToggleEditor)) { _ in
            mode.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .blackGlassFocusEditor)) { _ in
            mode = .uncooked
            requestFocusAtStart = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .blackGlassFindInNote)) { _ in
            guard mode == .uncooked else { return }
            showFind = true
            isFindFieldFocused = true
        }
    }

    private func loadContent() {
        let loaded = (try? String(contentsOf: fileItem.url, encoding: .utf8)) ?? ""
        text = loaded
        lastSaved = loaded
        showFind = false
        findQuery = ""
        if mode == .uncooked {
            requestFocusAtStart = true
        }
    }

    private func queueAutoSave(_ newText: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            writeIfNeeded(newText)
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        writeIfNeeded(text)
    }

    private func writeIfNeeded(_ newText: String) {
        guard newText != lastSaved else { return }
        do {
            try newText.write(to: fileItem.url, atomically: true, encoding: .utf8)
            lastSaved = newText
            onContentSaved?(fileItem.url, newText)
        } catch {
            NSLog("BlackGlass save failed: \(error.localizedDescription)")
        }
    }
}
