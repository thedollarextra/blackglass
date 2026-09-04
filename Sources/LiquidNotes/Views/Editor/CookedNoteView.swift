import SwiftUI
import WebKit
import AppKit

struct CookedNoteView: NSViewRepresentable {
    var markdown: String
    var fileItem: FileItem
    var vaultManager: VaultManager
    var themeClass: String
    /// Wiki-link clicks report the target here rather than touching selection
    /// directly, since what "navigate" means differs between the main
    /// window (reveal in the sidebar) and a popped-out note window (open
    /// another pop-out).
    var onNavigate: (FileItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(vaultManager: vaultManager, onNavigate: onNavigate) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.vaultManager = vaultManager
        context.coordinator.onNavigate = onNavigate
        guard let vault = vaultManager.activeVault else { return }
        let coordinator = context.coordinator
        // `updateNSView` reruns on every redraw of whatever contains this
        // view, not just when our own inputs change — e.g. another window
        // creating a note touches `vaultManager.fileTree`, which this editor
        // observes (via `vaultManager`) but doesn't render from. Re-parsing
        // the note's markdown and rebuilding its HTML on every one of those
        // was pure waste; skip it unless something we actually render from
        // has changed since the last call.
        guard markdown != coordinator.lastMarkdown
                || fileItem.url != coordinator.lastFileURL
                || themeClass != coordinator.lastThemeClass
                || vault.url != coordinator.lastVaultURL else { return }
        coordinator.lastMarkdown = markdown
        coordinator.lastFileURL = fileItem.url
        coordinator.lastThemeClass = themeClass
        coordinator.lastVaultURL = vault.url
        let html = OFMHTML.render(
            markdown: markdown,
            current: fileItem.url,
            vault: vault.url,
            wiki: vaultManager.wikiIndex,
            search: vaultManager.searchIndex,
            mode: OFMRenderMode(web: false, themeClass: themeClass)
        )
        if html != coordinator.lastHTML {
            coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: vault.url)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var vaultManager: VaultManager
        var onNavigate: (FileItem) -> Void
        var lastHTML: String = ""
        // Inputs that produced `lastHTML` — see the skip check in `updateNSView`.
        var lastMarkdown: String?
        var lastFileURL: URL?
        var lastThemeClass: String?
        var lastVaultURL: URL?

        init(vaultManager: VaultManager, onNavigate: @escaping (FileItem) -> Void) {
            self.vaultManager = vaultManager
            self.onNavigate = onNavigate
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "liquidnotes" {
                decisionHandler(.cancel)
                let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "path" })?.value
                    ?? url.host
                if let path, let vault = vaultManager.activeVault {
                    let dest = vault.url.appendingPathComponent(path)
                    onNavigate(FileItem(url: dest, isDirectory: false))
                }
                return
            }
            if navigationAction.navigationType == .linkActivated, url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
