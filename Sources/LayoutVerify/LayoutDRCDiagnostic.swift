import Foundation

public struct LayoutDRCDiagnostic: Hashable, Sendable, Codable {
    public var code: String
    public var severity: LayoutDRCDiagnosticSeverity
    public var message: String
    public var cellID: UUID?
    public var suggestedActions: [String]

    public init(
        code: String,
        severity: LayoutDRCDiagnosticSeverity,
        message: String,
        cellID: UUID? = nil,
        suggestedActions: [String] = []
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.cellID = cellID
        self.suggestedActions = suggestedActions
    }
}
