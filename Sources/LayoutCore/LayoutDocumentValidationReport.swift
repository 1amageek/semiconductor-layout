public struct LayoutDocumentValidationReport: Hashable, Sendable, Codable {
    public let findings: [LayoutDocumentValidationFinding]

    public var errors: [LayoutDocumentValidationFinding] {
        findings.filter { $0.severity == .error }
    }

    public var warnings: [LayoutDocumentValidationFinding] {
        findings.filter { $0.severity == .warning }
    }

    public var isValid: Bool {
        errors.isEmpty
    }

    public init(findings: [LayoutDocumentValidationFinding]) {
        self.findings = findings
    }
}
