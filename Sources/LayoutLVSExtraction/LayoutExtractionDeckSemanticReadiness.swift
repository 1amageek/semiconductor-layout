public struct LayoutExtractionDeckSemanticReadiness: Sendable, Hashable, Codable {
    public let issues: [LayoutExtractionDeckSemanticIssue]

    public init(issues: [LayoutExtractionDeckSemanticIssue]) {
        self.issues = Array(Set(issues)).sorted()
    }

    public var isReady: Bool {
        issues.isEmpty
    }
}
