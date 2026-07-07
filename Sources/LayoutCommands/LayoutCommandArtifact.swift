public struct LayoutCommandArtifact: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let format: String
    public let path: String
    public let sha256: String
    public let byteCount: Int

    public init(id: String, kind: String, format: String, path: String, sha256: String, byteCount: Int) {
        self.id = id
        self.kind = kind
        self.format = format
        self.path = path
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}
