import Foundation

public struct Vault: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var path: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, path: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    public var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
