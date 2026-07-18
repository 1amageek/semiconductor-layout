public enum LayoutExtractionDeckSemanticIssue: Sendable, Hashable, Codable, Comparable {
    case missingRequiredFamily(String)
    case unsupportedRequiredFamily(family: String, reasonCode: String)

    public static func < (
        lhs: LayoutExtractionDeckSemanticIssue,
        rhs: LayoutExtractionDeckSemanticIssue
    ) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    private var sortKey: String {
        switch self {
        case .missingRequiredFamily(let family):
            return "0:missing:\(family)"
        case .unsupportedRequiredFamily(let family, let reasonCode):
            return "1:unsupported-required:\(family):\(reasonCode)"
        }
    }
}
