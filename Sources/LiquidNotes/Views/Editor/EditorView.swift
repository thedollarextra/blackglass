import SwiftUI

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
    var onNavigate: (FileItem) -> Void
    var onContentSaved: ((URL, String) -> Void)? = nil
    @ObservedObject private var settingsStore = SettingsStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var text: String = ""
    @State private var mode: EditorMode = .uncooked
    @State private var saveTask: Task<Void, Never>?
    @State private var lastSaved: String = ""
    @FocusState private var isEditorFocused: Bool

    private var themeClass: String {
        switch settingsStore.settings.appearance {
        case .light: "theme-light"
        case .dark: "theme-dark"
        case .system: "theme-system"
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SidebarToggle(sidebarVisible: $sidebarVisible)
                Text(fileItem.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .help(fileItem.url.path)

                Spacer(minLength: 8)

                Button(action: { openWindow(id: LiquidNotesApp.noteWindowID, value: fileItem.url) }) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Open in New Window")

                EggModeToggle(mode: $mode)
            }
            .padding(.leading, sidebarVisible ? 14 : 78)
            .padding(.trailing, 14)
            .frame(height: WindowChrome.titlebarRowHeight)
            .frame(maxWidth: .infinity)

            Group {
                if mode == .uncooked {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .padding(16)
                        .scrollContentBackground(.hidden)
                        .focused($isEditorFocused)
                        .onChange(of: text) { _, newText in
                            queueAutoSave(newText)
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
        .onReceive(NotificationCenter.default.publisher(for: .liquidNotesToggleEditor)) { _ in
            mode.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .liquidNotesFocusEditor)) { _ in
            mode = .uncooked
            DispatchQueue.main.async {
                isEditorFocused = true
            }
        }
    }

    private func loadContent() {
        let loaded = (try? String(contentsOf: fileItem.url, encoding: .utf8)) ?? ""
        text = loaded
        lastSaved = loaded
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
            NSLog("LiquidNotes save failed: \(error.localizedDescription)")
        }
    }
}
