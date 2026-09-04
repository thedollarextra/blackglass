import SwiftUI

/// One pop-out note window: `MainWindowView` pre-selecting `url`'s note,
/// sidebar hidden by default per Settings. Its own `WindowGroup` is keyed by
/// the URL so re-popping the same note focuses the existing window instead
/// of opening a duplicate.
struct NoteWindowView: View {
    let vaultManager: VaultManager
    let server: NoteServer
    let url: URL

    var body: some View {
        MainWindowView(
            vaultManager: vaultManager,
            server: server,
            initialSelection: FileItem(url: url, isDirectory: false),
            sidebarVisible: !SettingsStore.shared.settings.hidePopOutSidebarByDefault
        )
    }
}
