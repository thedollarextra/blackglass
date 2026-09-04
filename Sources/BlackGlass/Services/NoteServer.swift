import Foundation
import Network
import Combine
import AppKit
import Darwin

struct APINode: Codable {
    var title: String
    var path: String
    var isDirectory: Bool
    var children: [APINode]?
}

@MainActor
final class NoteServer: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var boundPort: Int = 0

    private var listener: NWListener?
    private weak var vaultManager: VaultManager?

    func attach(vaultManager: VaultManager) {
        self.vaultManager = vaultManager
    }

    func start(port: Int, localhostOnly: Bool) {
        stop()
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
        isRunning = false
        boundPort = 0
    }

    func apply(_ settings: AppSettings) {
        if settings.serverEnabled || settings.serverAutoStart && settings.serverEnabled {
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
        let path = request.path
        let route = path.split(separator: "?").first.map(String.init) ?? path
        if route == "/api/appearance" {
            return handleAppearance(request)
        }
        if path.hasPrefix("/api/") {
            return handleAPI(request)
        }
        return serveStatic(path: path)
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
        let route = request.path.split(separator: "?").first.map(String.init) ?? request.path

        let jsonBody = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]

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
            let nodes = vaultManager.fileTree.map { Self.encode($0, vault: vaultURL) }
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
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else {
                return HTTPResponse(status: 404, body: Data("Not found".utf8))
            }
            return HTTPResponse(status: 200, contentType: Self.mime(url.pathExtension), body: data)

        default:
            return .json(["error": "Not found"], status: 404)
        }
    }

    private func serveStatic(path rawPath: String) -> HTTPResponse {
        let trimmed = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        var relative = trimmed == "/" ? "index.html" : String(trimmed.dropFirst())
        if relative.hasSuffix("/") { relative += "index.html" }
        if relative.contains("..") {
            return HTTPResponse(status: 403, body: Data("Forbidden".utf8))
        }
        guard let root = Self.webRoot() else {
            return HTTPResponse(status: 500, body: Data("Web UI missing".utf8))
        }
        var file = root.appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: file.path) {
            file = root.appendingPathComponent("index.html")
        }
        guard let data = try? Data(contentsOf: file) else {
            return HTTPResponse(status: 404, body: Data("Not found".utf8))
        }
        return HTTPResponse(status: 200, contentType: Self.mime(file.pathExtension), body: data)
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

    private static func encode(_ item: FileItem, vault: URL) -> APINode {
        APINode(
            title: item.displayTitle,
            path: relative(item.url, vault: vault),
            isDirectory: item.isDirectory,
            children: item.children?.map { encode($0, vault: vault) }
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
    static func receive(on connection: NWConnection, complete: @escaping @Sendable (HTTPRequest) -> Void) {
        let box = BufferBox()
        func loop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data { box.data.append(data) }
                if let request = HTTPRequest.parse(box.data) {
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
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

final class BufferBox: @unchecked Sendable {
    var data = Data()
}

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    var query: [String: String]

    var bodyString: String { String(data: body, encoding: .utf8) ?? "" }

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
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
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let have = data.count - bodyStart
        if have < contentLength { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
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
        return HTTPRequest(method: parts[0], path: path, headers: headers, body: body, query: query)
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String = "text/plain; charset=utf-8"
    var body: Data

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    func serialized() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "OK"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}
