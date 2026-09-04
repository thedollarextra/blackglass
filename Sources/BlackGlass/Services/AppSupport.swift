import Foundation

/// Where settings, the vault list and the sidebar's manual ordering live.
///
/// The app was called LiquidNotes before it was BlackGlass. An existing
/// install's data sits under the old name, so it's brought across once on
/// first launch — otherwise renaming the app would look, from the outside,
/// exactly like it had forgotten every vault you'd ever added.
enum AppSupport {
    static let folder: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let current = base.appendingPathComponent("BlackGlass", isDirectory: true)
        let legacy = base.appendingPathComponent("LiquidNotes", isDirectory: true)

        // Copied rather than moved: if anything about the new location goes
        // wrong, the old install's data is still sitting there intact.
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.copyItem(at: legacy, to: current)
        }
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }()
}
