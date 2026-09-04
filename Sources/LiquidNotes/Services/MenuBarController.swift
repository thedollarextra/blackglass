import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, ObservableObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var settingsObserver: AnyCancellable?
    private var windowObservers: [NSObjectProtocol] = []

    /// Opens a fresh window of the "main" WindowGroup. SwiftUI deallocates a
    /// WindowGroup's window when it closes (unlike a plain NSWindow hidden
    /// behind an accessory activation policy), so once the last window is
    /// closed there is nothing left in `NSApp.windows` to bring forward —
    /// only `openWindow(id:)` can make a new one. Set from the App's body,
    /// since that environment action isn't reachable from plain AppKit code.
    var openWindowAction: (() -> Void)?

    /// Keeps the status item (and the app off the Dock) even when neither
    /// `menuBarMode` nor `serverEnabled` is on. Set for the one launch macOS
    /// silently starts this app at login — with its usual window suppressed,
    /// this is the only way back in without Force Quit/Activity Monitor.
    var forceStatusItem = false

    override init() {
        super.init()
    }

    func start() {
        if settingsObserver == nil {
            settingsObserver = SettingsStore.shared.$settings
                .removeDuplicates()
                .sink { [weak self] _ in self?.syncAppearance() }
        }
        if windowObservers.isEmpty {
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.willCloseNotification,
            ]
            for name in names {
                windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in
                        // willClose fires before the window is gone from NSApp.windows.
                        DispatchQueue.main.async {
                            MenuBarController.shared.syncAppearance()
                        }
                    }
                })
            }
        }
        syncAppearance()
    }

    /// Dock icon while a window is open (like a normal app).
    /// Menu extra stays whenever the web server (or menu-bar mode) is on.
    func syncAppearance() {
        installOrRemoveStatusItem()
        let settings = SettingsStore.shared.settings
        let keepMenu = settings.menuBarMode || settings.serverEnabled || forceStatusItem
        let hideDock = !hasOpenWindow && keepMenu
        let policy: NSApplication.ActivationPolicy = hideDock ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular {
                NSApp.activate(ignoringOtherApps: false)
            }
        }
    }

    /// Just the status item, without touching the accessory/regular
    /// activation policy. Safe to call at launch, before it's known whether
    /// SwiftUI's default window has appeared yet — see the call site in
    /// `AppDelegate.applicationDidFinishLaunching` for why deciding the
    /// policy that early is unsafe.
    func installStatusItemOnly() {
        installOrRemoveStatusItem()
    }

    private func installOrRemoveStatusItem() {
        let settings = SettingsStore.shared.settings
        if settings.menuBarMode || settings.serverEnabled || forceStatusItem {
            installItem()
        } else {
            removeItem()
        }
    }

    var hasOpenWindow: Bool {
        NSApp.windows.contains { window in
            guard window.canBecomeMain else { return false }
            return window.isVisible || window.isMiniaturized
        }
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        // `setActivationPolicy`/`activate` aren't synchronous — the window
        // server needs a run-loop turn to actually finish switching the app
        // from accessory to regular before it will key/composite a window.
        // Calling `makeKeyAndOrderFront` in the same turn (as this used to)
        // reported success (`isVisible == true`) while the window stayed
        // uncomposited (`isKeyWindow == false`, occluded, `NSApp.isActive`
        // still false even right after `activate`) — silently doing nothing
        // from the user's perspective. Deferring one tick, and re-issuing
        // activation right before actually keying the window, fixes it.
        DispatchQueue.main.async { [weak self] in
            self?.reallyShowMainWindow()
        }
    }

    private func reallyShowMainWindow() {
        // `NSApp.activate` alone was observed not actually activating this
        // process when called right after a status-item click on an
        // accessory-policy app (`NSApp.isActive` stayed false even after it
        // returned) — `NSRunningApplication.activate` is the more reliable
        // "make *this* background process the frontmost app" call for
        // exactly that scenario.
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        var didShow = false
        // Only a tagged main window counts: with note pop-out windows also
        // supported now, `canBecomeMain` alone could match one of those and
        // skip surfacing (or creating) an actual main window.
        for window in NSApp.windows where window.identifier == .liquidNotesMainWindow {
            window.makeKeyAndOrderFront(nil)
            configureLiquidNotesWindow(window)
            didShow = true
        }
        if !didShow {
            // No existing main window to reuse (it was closed, not just
            // hidden behind the accessory policy) — ask SwiftUI to create one.
            if let openWindowAction {
                openWindowAction()
            } else {
                NSApp.windows.forEach { $0.makeKeyAndOrderFront(nil) }
            }
        }
        syncAppearance()
    }

    private func installItem() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                let image = Self.shardIcon(pointSize: 16)
                image.isTemplate = true
                button.image = image
                button.toolTip = "BlackGlass"
            }
            statusItem = item
        }
        statusItem?.menu = buildMenu()
    }

    /// The same angular shard silhouette as the app icon (see
    /// `scripts/make_app_icon.swift`), rendered small as a template image so
    /// the menu bar tints it automatically for light/dark bars. Scaled up
    /// 1.25x from the app icon's own points (about their shared center) —
    /// at menu bar size the icon's natural margins read as too small.
    private static func shardIcon(pointSize: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            let points: [(CGFloat, CGFloat)] = [
                (0.375, 0.85), (0.65, 0.9625), (0.5625, 0.7375),
                (0.7125, 0.60), (0.4875, 0.0375), (0.325, 0.3875),
            ]
            let path = NSBezierPath()
            for (index, point) in points.enumerated() {
                let p = NSPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + point.1 * rect.height)
                if index == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
    }

    private func removeItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open BlackGlass", action: #selector(Self.openApp(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Settings…", action: #selector(Self.openSettings(_:)), keyEquivalent: ",")
            .target = self
        if SettingsStore.shared.settings.serverEnabled {
            menu.addItem(.separator())
            let settings = SettingsStore.shared.settings
            let host = settings.serverLocalhostOnly ? "127.0.0.1" : (NoteServer.lanIPv4() ?? "127.0.0.1")
            let serverItem = menu.addItem(
                withTitle: "Web Server: http://\(host):\(settings.serverPort)",
                action: nil,
                keyEquivalent: ""
            )
            serverItem.isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit BlackGlass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openApp(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func openSettings(_ sender: Any?) {
        showMainWindow()
        NotificationCenter.default.post(name: .liquidNotesOpenSettings, object: nil)
    }
}
