import SwiftUI
import WebKit
import AppKit

struct CookedNoteView: NSViewRepresentable {
    var markdown: String
    var fileItem: FileItem
    var vaultManager: VaultManager
    var themeClass: String
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
        let html = OFMHTML.render(
            markdown: markdown,
            current: fileItem.url,
            vault: vault.url,
            wiki: vaultManager.wikiIndex,
            search: vaultManager.searchIndex,
            mode: OFMRenderMode(web: false, themeClass: themeClass)
        )
        if html != context.coordinator.lastHTML {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: vault.url)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var vaultManager: VaultManager
        var onNavigate: (FileItem) -> Void
        var lastHTML: String = ""

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
