public struct LayoutExtractionIssue: Sendable, Hashable, Codable {
    public enum Severity: String, Sendable, Hashable, Codable {
        case warning
        case blocking
    }

    public let code: String
    public let severity: Severity
    public let message: String
    public let affectedObjectIDs: [LayoutExtractionObjectID]
    public let sourceLocation: LayoutExtractionSourceLocation?

    public init(
        code: String,
        severity: Severity,
        message: String,
        affectedObjectIDs: [LayoutExtractionObjectID] = [],
        sourceLocation: LayoutExtractionSourceLocation? = nil
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.affectedObjectIDs = affectedObjectIDs.sorted()
        self.sourceLocation = sourceLocation
    }
}
