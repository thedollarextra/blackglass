import Foundation
import Network
import Combine
import AppKit
import Darwin

struct APINode: Codable {
    var title: String
    var path: String
    var isDirectory: Bool
    /// Set only on folders the user has dragged into a manual order, so the
    /// web client can offer to put one back in name order without having to
    /// ask about every folder it draws. Omitted from the JSON otherwise.
    var manualOrder: Bool?
    var children: [APINode]?
}

@MainActor
final class NoteServer: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var boundPort: Int = 0

    private var listener: NWListener?
    private weak var vaultManager: VaultManager?
    /// Whether this launch has already tried to bring the server up, so the
    /// attempt isn't repeated on every SwiftUI body evaluation.
    private var didLaunchStart = false
    /// What the live listener was asked for, recorded synchronously. `start`
    /// compares against these; `isRunning` can't be used for that, because it
    /// only becomes true once the listener reports `.ready`, well after the
    /// call that created it returned.
    private var requestedPort: Int?
    private var requestedLocalhostOnly: Bool?

    func attach(vaultManager: VaultManager) {
        self.vaultManager = vaultManager
    }

    /// Brings the server up for this launch, if the settings ask for it.
    ///
    /// Called from the app's `body` rather than a view's `onAppear`, because
    /// with `menuBarMode` on the app can launch with no window at all — and
    /// `MainWindowView.onAppear` was the only thing that ever called `start()`.
    /// Serving the vault to a phone is much of the point of a menu-bar launch,
    /// so it cannot depend on a window being opened first.
    func startOnLaunch(vaultManager: VaultManager, settings: SettingsStore) {
        guard !didLaunchStart else { return }
        didLaunchStart = true
        attach(vaultManager: vaultManager)
        // Deferred by one turn of the run loop: writing `serverEnabled` back
        // while the view tree is being evaluated is what SwiftUI warns about.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let current = settings.settings
            guard current.serverEnabled || current.serverAutoStart else { return }
            settings.settings.serverEnabled = true
            self.start(port: current.serverPort, localhostOnly: current.serverLocalhostOnly)
        }
    }

    func start(port: Int, localhostOnly: Bool) {
        // Already serving exactly this — nothing to do. Without this guard a
        // second caller tears the listener down and immediately asks for the
        // same port back, and `NWListener.cancel()` completes asynchronously:
        // the replacement loses the race to the socket it just closed and dies
        // with EADDRINUSE, leaving nothing serving at all. Two callers landing
        // within a few hundred milliseconds of each other at launch is the
        // normal case, not a rare one.
        if listener != nil, requestedPort == port, requestedLocalhostOnly == localhostOnly {
            return
        }
        stop()
        requestedPort = port
        requestedLocalhostOnly = localhostOnly
        lastError = nil
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            lastError = "Invalid port"
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if localhostOnly {
            let host = NWEndpoint.Host("127.0.0.1")
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: nwPort)
        }

        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                HTTPConnection.receive(on: connection) { request in
                    Task { @MainActor in
                        let response = self?.handle(request) ?? HTTPResponse(status: 503, body: Data("Server unavailable".utf8))
                        HTTPConnection.send(response, on: connection)
                    }
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.boundPort = port
                        self?.lastError = nil
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        requestedPort = nil
        requestedLocalhostOnly = nil
        isRunning = false
        boundPort = 0
    }

    func apply(_ settings: AppSettings) {
        if settings.serverEnabled {
            start(port: settings.serverPort, localhostOnly: settings.serverLocalhostOnly)
        } else {
            stop()
        }
    }

    var listenURL: String {
        let port = boundPort == 0 ? SettingsStore.shared.settings.serverPort : boundPort
        if SettingsStore.shared.settings.serverLocalhostOnly {
            return "http://127.0.0.1:\(port)"
        }
        return "http://\(Self.lanIPv4() ?? "127.0.0.1"):\(port)"
    }

    static func lanIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            if isUp, !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(decoding: hostname.map { UInt8(bitPattern: $0) }.prefix { $0 != 0 }, as: UTF8.self)
                    if ip.hasPrefix("192.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                        address = ip
                        break
                    }
                    if address == nil { address = ip }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return address
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, contentType: "text/plain; charset=utf-8", body: Data())
        }
        // `HTTPRequestHead.parse` already split the query string off, so
        // `path` is the bare route — the three `split(separator: "?")` calls
        // this and the handlers below made per request were re-splitting a
        // string that can no longer contain a `?`.
        let path = request.path
        if path == "/api/appearance" {
            return handleAppearance(request)
        }
        if path.hasPrefix("/api/") {
            return handleAPI(request)
        }
        return serveStatic(request)
    }

    private func handleAppearance(_ request: HTTPRequest) -> HTTPResponse {
        switch request.method {
        case "GET":
            let settings = SettingsStore.shared.settings
            return .json([
                "appearance": settings.appearance.rawValue,
                "searchAlwaysVisible": settings.webSearchAlwaysVisible
            ])
        default:
            return .json(["error": "Not found"], status: 404)
        }
    }

    private func handleAPI(_ request: HTTPRequest) -> HTTPResponse {
        guard let vaultManager, let vault = vaultManager.activeVault else {
            return .json(["error": "No active vault"], status: 400)
        }
        let vaultURL = vault.url
        let route = request.path

        // Only the mutating routes carry a body. Parsing unconditionally made
        // every GET — the tree, each note open, every keystroke of search —
        // pay for a throwing `JSONSerialization` call on empty data.
        let jsonBody: [String: Any]? = request.body.isEmpty
            ? nil
            : (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]

        switch (request.method, route) {
        case ("GET", "/api/vault"):
            return .json(["name": vault.name, "path": vault.path, "id": vault.id.uuidString])

        case ("GET", "/api/vaults"):
            let list: [[String: Any]] = vaultManager.vaults.map {
                [
                    "id": $0.id.uuidString,
                    "name": $0.name,
                    "path": $0.path,
                    "active": $0.id == vault.id
                ]
            }
            return .json(list)

        case ("POST", "/api/vault/select"):
            guard let idString = jsonBody?["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let match = vaultManager.vaults.first(where: { $0.id == id }) else {
                return .json(["error": "Unknown vault"], status: 400)
            }
            vaultManager.selectVault(match)
            return .json(["ok": true, "name": match.name, "id": match.id.uuidString])

        case ("GET", "/api/tree"):
            vaultManager.refreshFileTree()
            let nodes = vaultManager.fileTree.map { Self.encode($0, vault: vaultURL, manager: vaultManager) }
            return .json(nodes)

        case ("GET", "/api/note"):
            guard let rel = request.query["path"], let url = Self.resolve(rel, vault: vaultURL) else {
                return .json(["error": "Missing path"], status: 400)
            }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let title = FileItem(url: url, isDirectory: false).displayTitle
            return .json(["title": title, "path": rel, "content": text])

        case ("PUT", "/api/note"):
            guard let rel = request.query["path"], let url = Self.resolve(rel, vault: vaultURL) else {
                return .json(["error": "Missing path"], status: 400)
            }
            let content: String
            if let c = jsonBody?["content"] as? String {
                content = c
            } else {
                content = request.bodyString
            }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                return .json(["ok": true])
            } catch {
                return .json(["error": error.localizedDescription], status: 500)
            }

        case ("POST", "/api/note"):
            var name = "Untitled"
            var directory: URL?
            if let n = jsonBody?["name"] as? String, !n.isEmpty { name = n }
            if let d = jsonBody?["directory"] as? String, let resolved = Self.resolve(d, vault: vaultURL) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
                    directory = resolved
                } else {
                    directory = resolved.deletingLastPathComponent()
                }
            }
            if let item = vaultManager.createNote(named: name, in: directory) {
                let rel = Self.relative(item.url, vault: vaultURL)
                return .json(["ok": true, "path": rel, "title": item.displayTitle])
            }
            return .json(["error": "Could not create note"], status: 500)

        case ("PATCH", "/api/note"):
            guard let rel = jsonBody?["path"] as? String ?? request.query["path"],
                  let url = Self.resolve(rel, vault: vaultURL),
                  let title = jsonBody?["title"] as? String else {
                return .json(["error": "Missing path or title"], status: 400)
            }
            let item = FileItem(url: url, isDirectory: Self.isDirectory(url))
            let renamed = vaultManager.commitRename(item, to: title, focusEditor: false)
            return .json([
                "ok": true,
                "path": Self.relative(renamed.url, vault: vaultManager.activeVault?.url ?? vaultURL),
                "title": renamed.displayTitle,
                "isDirectory": renamed.isDirectory
            ])

        case ("POST", "/api/note/collapse"):
            // Expand/Collapse All for a folder: returns every folder ID in its
            // subtree so the web client can bulk-update its own collapsed set
            // without a round trip per folder.
            guard let rel = jsonBody?["path"] as? String, let url = Self.resolve(rel, vault: vaultURL) else {
                return .json(["error": "Missing path"], status: 400)
            }
            vaultManager.refreshFileTree()
            let item = vaultManager.findInTree(id: url.standardizedFileURL.path) ?? FileItem(url: url, isDirectory: true)
            let ids = item.folderIDsInSubtree.map { Self.relative(URL(fileURLWithPath: $0), vault: vaultURL) }
            return .json(["ok": true, "paths": ids])

        case ("POST", "/api/tree/move"):
            // The tree's drag and drop, in one route. `reorderItems` covers
            // both halves of it: a drop onto a different folder moves on
            // disk, a drop between two rows of the folder something already
            // lives in is a pure reorder, and a drop that does both does
            // both. `before` is the sibling the items land in front of, or
            // absent to park them at the end.
            guard let rels = jsonBody?["paths"] as? [String], !rels.isEmpty else {
                return .json(["error": "Missing paths"], status: 400)
            }
            guard let destination = Self.resolve(jsonBody?["destination"] as? String ?? "", vault: vaultURL),
                  Self.isDirectory(destination) else {
                return .json(["error": "Destination is not a folder"], status: 400)
            }
            // Straight off the tree where possible: a folder's `FileItem`
            // built here would carry no children, and `moveItems` needs the
            // subtree to remap the paths of everything inside it.
            let items = rels.compactMap { rel -> FileItem? in
                guard let url = Self.resolve(rel, vault: vaultURL),
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return vaultManager.findInTree(id: url.standardizedFileURL.path)
                    ?? FileItem(url: url, isDirectory: Self.isDirectory(url))
            }
            guard !items.isEmpty else {
                return .json(["error": "Nothing to move"], status: 400)
            }
            let before = (jsonBody?["before"] as? String)
                .flatMap { Self.resolve($0, vault: vaultURL) }?
                .lastPathComponent
            let remap = vaultManager.reorderItems(items, into: destination, before: before)
            // Handed back vault-relative, since absolute paths mean nothing
            // to the client — it needs them to follow a moved note that is
            // currently open, and to keep collapsed folders collapsed.
            var moved: [String: String] = [:]
            for (from, to) in remap {
                moved[Self.relative(URL(fileURLWithPath: from), vault: vaultURL)] =
                    Self.relative(URL(fileURLWithPath: to), vault: vaultURL)
            }
            return .json(["ok": true, "moved": moved] as [String: Any])

        case ("POST", "/api/tree/order/clear"):
            // Undoes a manual drag order, putting a folder back in name
            // order. Without this a single reorder would freeze that folder
            // out of alphabetical sorting permanently from the web client.
            guard let folder = Self.resolve(jsonBody?["path"] as? String ?? "", vault: vaultURL),
                  Self.isDirectory(folder) else {
                return .json(["error": "Not a folder"], status: 400)
            }
            vaultManager.clearManualOrder(of: folder)
            return .json(["ok": true])

        case ("POST", "/api/import"):
            // Files dragged in from the desktop onto the web client. The
            // browser can only give us bytes, so unlike the native drop
            // these are written rather than copied from a source URL.
            guard let destination = Self.resolve(jsonBody?["destination"] as? String ?? "", vault: vaultURL),
                  Self.isDirectory(destination) else {
                return .json(["error": "Destination is not a folder"], status: 400)
            }
            let uploads: [VaultManager.Upload] = (jsonBody?["files"] as? [[String: Any]] ?? []).compactMap {
                guard let name = $0["path"] as? String,
                      let encoded = $0["data"] as? String,
                      let bytes = Data(base64Encoded: encoded) else { return nil }
                return VaultManager.Upload(relativePath: name, data: bytes)
            }
            guard !uploads.isEmpty else {
                return .json(["error": "No files"], status: 400)
            }
            let written = vaultManager.importUploads(uploads, into: destination)
            return .json([
                "ok": true,
                "imported": written.count,
                "skipped": uploads.count - written.count,
                "paths": written.map { Self.relative($0, vault: vaultURL) }
            ] as [String: Any])

        case ("DELETE", "/api/note"):
            guard let rel = request.query["path"], let url = Self.resolve(rel, vault: vaultURL) else {
                return .json(["error": "Missing path"], status: 400)
            }
            vaultManager.deleteItems([FileItem(url: url, isDirectory: Self.isDirectory(url))])
            return .json(["ok": true])

        case ("GET", "/api/search"):
            let q = request.query["q"] ?? ""
            let results = vaultManager.search(query: q).map {
                [
                    "title": $0.title,
                    "path": Self.relative($0.fileItem.url, vault: vaultURL),
                    "snippet": $0.snippet
                ]
            }
            return .json(results)

        case ("GET", "/api/graph"):
            let snapshot = GraphScanner.snapshot(vault: vaultURL)
            return .json([
                "nodes": snapshot.nodes.map { ["id": $0.path, "title": $0.title, "path": $0.path, "unresolved": $0.unresolved] as [String: Any] },
                "edges": snapshot.edges.map { ["from": $0.from, "to": $0.to] as [String: Any] }
            ] as [String: Any])

        case ("GET", "/api/render"):
            guard let rel = request.query["path"], let url = Self.resolve(rel, vault: vaultURL) else {
                return .json(["error": "Missing path"], status: 400)
            }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let theme: String
            switch SettingsStore.shared.settings.appearance {
            case .light: theme = "theme-light"
            case .dark: theme = "theme-dark"
            case .system: theme = "theme-system"
            }
            let html = OFMHTML.render(
                markdown: text,
                current: url,
                vault: vaultURL,
                wiki: vaultManager.wikiIndex,
                search: vaultManager.searchIndex,
                mode: OFMRenderMode(web: true, themeClass: theme)
            )
            return .json(["html": html, "title": FileItem(url: url, isDirectory: false).displayTitle])

        case ("GET", "/api/file"):
            guard let rel = request.query["path"], let url = Self.resolve(rel, vault: vaultURL) else {
                return .json(["error": "Missing path"], status: 400)
            }
            // Mapped rather than copied: an embedded image, PDF or video is
            // otherwise read wholly onto the heap only to be handed straight
            // to the socket. A missing file fails the read, so the separate
            // `fileExists` stat this used to do first was redundant.
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return HTTPResponse(status: 404, body: Data("Not found".utf8))
            }
            return HTTPResponse(status: 200, contentType: Self.mime(url.pathExtension), body: data)

        default:
            return .json(["error": "Not found"], status: 404)
        }
    }

    /// One bundled web asset: its bytes plus the validators a browser needs to
    /// stop asking for them again.
    private struct StaticAsset {
        let data: Data
        let contentType: String
        let etag: String
        let lastModified: String
    }

    /// The web UI ships inside the app bundle and cannot change while the app
    /// is running, so each file is read from disk exactly once per launch and
    /// every later hit is answered from memory — or, once the browser holds
    /// the ETag, with a bodyless 304. The whole set is well under 100 KB,
    /// which is the point when the server is the only live subsystem.
    private var staticAssets: [String: StaticAsset] = [:]

    private func serveStatic(_ request: HTTPRequest) -> HTTPResponse {
        var relative = request.path == "/" ? "index.html" : String(request.path.dropFirst())
        if relative.hasSuffix("/") { relative += "index.html" }
        if relative.contains("..") {
            return HTTPResponse(status: 403, body: Data("Forbidden".utf8))
        }
        guard let root = Self.webRoot() else {
            return HTTPResponse(status: 500, body: Data("Web UI missing".utf8))
        }
        // Unknown paths still fall through to the single-page app's entry
        // point, resolved to that name first so the cache holds one entry for
        // index.html rather than one per URL a client happens to ask for.
        guard let asset = staticAsset(relative, under: root) ?? staticAsset("index.html", under: root) else {
            return HTTPResponse(status: 404, body: Data("Not found".utf8))
        }
        // `no-cache` rather than a long `max-age`: these filenames carry no
        // content hash, so an app update has to be able to invalidate them
        // immediately. The conditional request still costs a couple of hundred
        // bytes instead of the whole file.
        let validators = [
            "ETag": asset.etag,
            "Last-Modified": asset.lastModified,
            "Cache-Control": "no-cache"
        ]
        if request.headers["if-none-match"] == asset.etag
            || request.headers["if-modified-since"] == asset.lastModified {
            return HTTPResponse(status: 304, contentType: asset.contentType, body: Data(), extraHeaders: validators)
        }
        return HTTPResponse(status: 200, contentType: asset.contentType, body: asset.data, extraHeaders: validators)
    }

    private func staticAsset(_ relative: String, under root: URL) -> StaticAsset? {
        if let cached = staticAssets[relative] { return cached }
        let file = root.appendingPathComponent(relative)
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let data = try? Data(contentsOf: file) else { return nil }
        let modified = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        let asset = StaticAsset(
            data: data,
            contentType: Self.mime(file.pathExtension),
            etag: "\"\(String(size, radix: 16))-\(String(Int(modified.timeIntervalSince1970), radix: 16))\"",
            lastModified: Self.httpDate(modified)
        )
        // Everything the bundle can plausibly hold here is a few KB; the cap
        // only stops something unexpectedly large from being pinned for the
        // life of the process.
        if data.count <= 2 * 1024 * 1024 { staticAssets[relative] = asset }
        return asset
    }

    /// RFC 1123 date for `Last-Modified`. Built per call rather than kept in a
    /// shared formatter: this runs once per asset per launch, and
    /// `DateFormatter` is not `Sendable`.
    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    /// Resolved once and reused: every static asset a browsing session pulls
    /// in (the page, its CSS, its JS, ...) was otherwise redoing this same
    /// bundle lookup, and the app's bundle location can't change mid-run.
    private static let cachedWebRoot: URL? = {
        // Deliberately never touches `Bundle.module`: SwiftPM's generated
        // accessor for it only checks `Bundle.main.bundleURL` (the `.app`
        // folder itself, not `Contents/Resources`, which is where a real
        // macOS bundle — and `build.sh` — actually puts resources) and a
        // hardcoded build-machine temp path as its only other fallback.
        // Referencing it at all crashes the whole app with `fatalError` the
        // moment neither exists, before this function's own working
        // fallbacks below ever get a chance to run.
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            return url.deletingLastPathComponent()
        }
        let nextToApp = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Web")
        if FileManager.default.fileExists(atPath: nextToApp.appendingPathComponent("index.html").path) {
            return nextToApp
        }
        return nil
    }()

    private static func webRoot() -> URL? { cachedWebRoot }

    @MainActor
    private static func encode(_ item: FileItem, vault: URL, manager: VaultManager) -> APINode {
        APINode(
            title: item.displayTitle,
            path: relative(item.url, vault: vault),
            isDirectory: item.isDirectory,
            manualOrder: item.isDirectory && manager.hasManualOrder(item.url) ? true : nil,
            children: item.children?.map { encode($0, vault: vault, manager: manager) }
        )
    }

    private static func relative(_ url: URL, vault: URL) -> String {
        let full = url.standardizedFileURL.path
        let root = vault.standardizedFileURL.path
        if full.hasPrefix(root) {
            return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    private static func resolve(_ relative: String, vault: URL) -> URL? {
        let cleaned = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.contains("..") else { return nil }
        let url = vault.appendingPathComponent(cleaned).standardizedFileURL
        let root = vault.standardizedFileURL.path
        guard url.path.hasPrefix(root) else { return nil }
        return url
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "json": return "application/json"
        case "md", "markdown", "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

}

enum HTTPConnection {
    /// A client that keeps sending without ever completing a request is
    /// otherwise unbounded memory in a process that may have no windows open
    /// at all. Generous enough for any note or attachment a `PUT` carries.
    private static let maxRequestBytes = 64 * 1024 * 1024

    static func receive(on connection: NWConnection, complete: @escaping @Sendable (HTTPRequest) -> Void) {
        let buffer = RequestBuffer()
        @Sendable func loop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if buffer.byteCount > maxRequestBytes {
                        connection.cancel()
                        return
                    }
                }
                if let request = buffer.completedRequest() {
                    complete(request)
                    return
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                loop()
            }
        }
        loop()
    }

    static func send(_ response: HTTPResponse, on connection: NWConnection) {
        let head = response.headerData()
        let body = response.body
        guard !body.isEmpty else {
            connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        // Two ordered sends rather than one joined blob: `NWConnection` keeps
        // them in sequence, and joining them copied every byte of the body a
        // second time just to prepend ~250 bytes of header.
        connection.send(content: head, completion: .contentProcessed { _ in })
        connection.send(content: body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Accumulates one request across reads. The header block is parsed exactly
/// once: re-running a whole-buffer parse after every 64 KB chunk made a large
/// `PUT` quadratic — each chunk rescanned every byte received so far for the
/// `\r\n\r\n` terminator and rebuilt the header dictionary from scratch.
final class RequestBuffer: @unchecked Sendable {
    private static let terminator = Data("\r\n\r\n".utf8)

    private var data = Data()
    private var searched = 0
    private var head: HTTPRequestHead?
    private var bodyStart = 0
    private var contentLength = 0

    var byteCount: Int { data.count }

    func append(_ chunk: Data) {
        data.append(chunk)
    }

    func completedRequest() -> HTTPRequest? {
        if head == nil {
            guard data.count >= Self.terminator.count else { return nil }
            // Back the scan up by the terminator's length so one straddling a
            // chunk boundary is still found, without restarting from byte 0.
            let from = max(searched - (Self.terminator.count - 1), 0)
            let lower = data.index(data.startIndex, offsetBy: from)
            guard let range = data.range(of: Self.terminator, in: lower..<data.endIndex) else {
                searched = data.count
                return nil
            }
            guard let parsed = HTTPRequestHead.parse(data[data.startIndex..<range.lowerBound]) else { return nil }
            head = parsed
            bodyStart = range.upperBound - data.startIndex
            contentLength = Int(parsed.headers["content-length"] ?? "0") ?? 0
        }
        guard let head = head, data.count - bodyStart >= contentLength else { return nil }
        let start = data.index(data.startIndex, offsetBy: bodyStart)
        return HTTPRequest(
            method: head.method,
            path: head.path,
            headers: head.headers,
            body: Data(data[start..<data.index(start, offsetBy: contentLength)]),
            query: head.query
        )
    }
}

/// A request line plus its headers, without the body.
struct HTTPRequestHead: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var query: [String: String]

    static func parse(_ headerData: Data) -> HTTPRequestHead? {
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let fullPath = parts[1]
        let pathParts = fullPath.split(separator: "?", maxSplits: 1).map(String.init)
        let path = pathParts.first ?? "/"
        var query: [String: String] = [:]
        if pathParts.count > 1 {
            for pair in pathParts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 {
                    query[kv[0].removingPercentEncoding ?? kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }
        return HTTPRequestHead(method: parts[0], path: path, headers: headers, query: query)
    }
}

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    var query: [String: String]

    var bodyString: String { String(data: body, encoding: .utf8) ?? "" }
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String = "text/plain; charset=utf-8"
    var body: Data
    /// Caching validators and anything else route-specific. Declared last so
    /// every existing `HTTPResponse(status:body:)` call site is unchanged.
    var extraHeaders: [String: String] = [:]

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        // No `.prettyPrinted`: the only consumer is `app.js`, and on the
        // array-of-objects payloads that come through here — `/api/graph`
        // above all — the indentation was a large fraction of the bytes.
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    /// Status line and headers only — the body goes out as its own send so a
    /// large attachment isn't copied again just to prepend these bytes.
    func headerData() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 304: reason = "Not Modified"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "OK"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in extraHeaders {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n\r\n"
        return Data(header.utf8)
    }
}
