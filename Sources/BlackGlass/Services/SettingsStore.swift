import Foundation
import Combine
import ServiceManagement
import AppKit
import SwiftUI

enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var iconName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var help: String {
        switch self {
        case .system: "Match this Mac’s light or dark appearance."
        case .light: "Always use a light appearance."
        case .dark: "Always use a dark appearance."
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    @MainActor
    func applyToApp() {
        switch self {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Which of the two searches ⌘K opens. Both stay reachable by clicking
/// their own icon in the sidebar's toolbar regardless of this setting.
enum CommandKSearch: String, Codable, CaseIterable, Identifiable {
    case omnisearch
    case sidebar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .omnisearch: "Omnisearch"
        case .sidebar: "Sidebar search"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var menuBarMode: Bool = false
    var launchAtLogin: Bool = false
    var serverEnabled: Bool = false
    var serverAutoStart: Bool = false
    var serverPort: Int = 8080
    var serverLocalhostOnly: Bool = true
    var appearance: AppAppearance = .system
    /// Web client: keep the search bar always visible instead of behind the
    /// toggle icon. Read by `/api/appearance`; the web app hides its own
    /// search toggle button when this is on, since it'd be redundant.
    var webSearchAlwaysVisible: Bool = false
    /// Mac app: keep the sidebar's search field always open instead of
    /// behind the toggle icon. Same idea as `webSearchAlwaysVisible`, for
    /// the native sidebar.
    var nativeSearchAlwaysVisible: Bool = false
    /// A popped-out note window starts with the sidebar hidden by default
    /// (it's meant to be a focused, single-note window) unless turned off.
    var hidePopOutSidebarByDefault: Bool = true
    var commandKSearch: CommandKSearch = .omnisearch

    enum CodingKeys: String, CodingKey {
        case menuBarMode, launchAtLogin, serverEnabled, serverAutoStart
        case serverPort, serverLocalhostOnly, appearance, webSearchAlwaysVisible
        case nativeSearchAlwaysVisible, hidePopOutSidebarByDefault, commandKSearch
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menuBarMode = try c.decodeIfPresent(Bool.self, forKey: .menuBarMode) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        serverEnabled = try c.decodeIfPresent(Bool.self, forKey: .serverEnabled) ?? false
        serverAutoStart = try c.decodeIfPresent(Bool.self, forKey: .serverAutoStart) ?? false
        serverPort = try c.decodeIfPresent(Int.self, forKey: .serverPort) ?? 8080
        serverLocalhostOnly = try c.decodeIfPresent(Bool.self, forKey: .serverLocalhostOnly) ?? true
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        webSearchAlwaysVisible = try c.decodeIfPresent(Bool.self, forKey: .webSearchAlwaysVisible) ?? false
        nativeSearchAlwaysVisible = try c.decodeIfPresent(Bool.self, forKey: .nativeSearchAlwaysVisible) ?? false
        hidePopOutSidebarByDefault = try c.decodeIfPresent(Bool.self, forKey: .hidePopOutSidebarByDefault) ?? true
        commandKSearch = try c.decodeIfPresent(CommandKSearch.self, forKey: .commandKSearch) ?? .omnisearch
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet {
            save()
            settings.appearance.applyToApp()
        }
    }

    private let url: URL

    private init() {
        url = AppSupport.folder.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        settings.launchAtLogin = on
    }

    var launchAtLoginStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }
}
