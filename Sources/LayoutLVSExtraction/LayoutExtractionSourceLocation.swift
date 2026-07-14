public struct LayoutExtractionSourceLocation: Sendable, Hashable, Codable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let sourceDigest: String

    public init(path: String, startLine: Int, endLine: Int, sourceDigest: String) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.sourceDigest = sourceDigest
    }
}
