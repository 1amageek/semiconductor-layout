import Foundation

public struct LayoutDocumentValidationFinding: Hashable, Sendable, Codable {
    public enum Severity: String, Hashable, Sendable, Codable {
        case warning
        case error
    }

    public let severity: Severity
    public let code: String
    public let summary: String
    public let entityID: String?

    public init(
        severity: Severity,
        code: String,
        summary: String,
        entityID: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.summary = summary
        self.entityID = entityID
    }
}
