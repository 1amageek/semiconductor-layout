public struct LayoutHierarchyInventory: Sendable, Hashable, Codable {
    public let topCell: String
    public let occurrences: [LayoutExtractionOccurrence]
    public let issues: [LayoutExtractionIssue]

    public init(
        topCell: String,
        occurrences: [LayoutExtractionOccurrence],
        issues: [LayoutExtractionIssue]
    ) {
        self.topCell = topCell
        self.occurrences = occurrences.sorted { $0.objectID < $1.objectID }
        self.issues = issues
    }

    public var isComplete: Bool {
        !issues.contains { $0.severity == .blocking }
    }
}
