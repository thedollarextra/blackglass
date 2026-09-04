import SwiftUI
import AppKit
import Carbon

@main
struct LiquidNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var vaultManager = VaultManager()
    @StateObject private var server = NoteServer()
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var menuBar = MenuBarController.shared
    @FocusedValue(\.windowState) private var windowState

    static let mainWindowID = "main"
    static let noteWindowID = "note"

    var body: some Scene {
        // Set here, not in `MainWindowView.onAppear`: macOS can relaunch this
        // app with zero windows restored (e.g. it was last quit with none
        // open), in which case that view's content closure never runs and
        // never gets a chance to register this — permanently breaking the
        // menu bar's "Open LiquidNotes" item for the rest of that launch,
        // since its fallback had nothing to call. `body` itself always runs
        // at launch regardless of window count, and `openWindow` is already
        // valid here (the "New Window" command below already reads it the
        // same way).
        // `let _ =` so this Void statement doesn't need to itself conform
        // to `Scene` — `@SceneBuilder` treats a local declaration as plain
        // code, not a block component, unlike a bare assignment statement.
        let _ = (menuBar.openWindowAction = { openWindow(id: Self.mainWindowID) })

        WindowGroup("BlackGlass", id: Self.mainWindowID) {
            MainWindowView(vaultManager: vaultManager, server: server)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    windowState?.requestNewNote(in: vaultManager)
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(windowState == nil)

                Button("New Folder") {
                    windowState?.requestNewFolder(in: vaultManager)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(windowState == nil)

                Button("New Window") {
                    openWindow(id: Self.mainWindowID)
                }
                .keyboardShortcut("t", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Button("Search Notes") {
                    windowState?.isSearching = true
                }
                .keyboardShortcut("f", modifiers: [.control])
                .disabled(windowState == nil)

                Button("Search Notes (Omnibar)") {
                    windowState?.showOmnibar.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(windowState == nil)

                Button("Toggle Uncooked / Cooked") {
                    NotificationCenter.default.post(name: .liquidNotesToggleEditor, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command])

                Button("Find in Note") {
                    NotificationCenter.default.post(name: .liquidNotesFindInNote, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Manage Vaults…") {
                    windowState?.showManageVaults = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(windowState == nil)

                Button("Settings…") {
                    windowState?.showSettings = true
                }
                .keyboardShortcut(",", modifiers: [.command])
                .disabled(windowState == nil)
            }
        }

        // One note, no sidebar — opened by the editor's pop-out button. Keyed
        // by the note's URL so re-popping the same note focuses its existing
        // window instead of opening a duplicate.
        WindowGroup("Note", id: Self.noteWindowID, for: URL.self) { $url in
            if let url {
                NoteWindowView(vaultManager: vaultManager, server: server, url: url)
                    .preferredColorScheme(settingsStore.settings.appearance.preferredColorScheme)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 640, height: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True for exactly the one launch where macOS silently reopened this
    /// app because "Open at login" is on, as opposed to the user launching
    /// it themselves. The first window `WindowChromeView` sees this turn
    /// closes itself instead of appearing (see its `viewDidMoveToWindow`),
    /// leaving only the menu bar extra — consumed there so every later
    /// window (including "New Window" later in the same run) behaves
    /// normally.
    var suppressInitialWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        suppressInitialWindow = Self.wasLaunchedAsLoginItem()
        if suppressInitialWindow {
            MenuBarController.shared.forceStatusItem = true
            NSApp.setActivationPolicy(.accessory)
        }
        SettingsStore.shared.settings.appearance.applyToApp()
        MenuBarController.shared.start()
        NSApp.windows.forEach { configureLiquidNotesWindow($0) }
        // Only the status item, not the accessory/regular activation-policy
        // decision: on a fresh launch, SwiftUI's own default `WindowGroup`
        // window isn't created until the run loop actually starts (after
        // this method returns), so `hasOpenWindow` still reads false here —
        // deciding the policy this early raced that window's own creation
        // and could switch to `.accessory` right as it was about to appear,
        // silently discarding it (it existed, `isVisible == true`, but never
        // actually got composited or keyed). `MenuBarController.start()`'s
        // window-lifecycle observers already call the full `syncAppearance()`
        // reactively once a window genuinely becomes key or the last one
        // closes, which is the only point this can be decided correctly.
        MenuBarController.shared.installStatusItemOnly()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let settings = SettingsStore.shared.settings
        if settings.menuBarMode || settings.serverEnabled || MenuBarController.shared.forceStatusItem {
            DispatchQueue.main.async {
                MenuBarController.shared.syncAppearance()
                // Nothing is on screen now; give back what the UI accumulated.
                LiquidNotesMemory.releaseIdle()
            }
            return false
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MenuBarController.shared.showMainWindow()
        }
        return true
    }

    /// Apple's standard signal for "this app was auto-launched at login" —
    /// the launch's own Apple Event carries this flag whether the app was
    /// registered the legacy way or via `SMAppService.mainApp.register()`.
    private static func wasLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication,
              let propData = event.paramDescriptor(forKeyword: keyAEPropData)
        else { return false }
        return propData.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
