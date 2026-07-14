public enum LayoutExtractionDeckProductionBlockReason: Sendable, Hashable, Codable, Comparable {
    case fixtureOnly
    case missingRequiredFamily(String)
    case unsupportedRequiredFamily(family: String, reasonCode: String)
    case unsupportedDirective(reasonCode: String)

    public static func < (
        lhs: LayoutExtractionDeckProductionBlockReason,
        rhs: LayoutExtractionDeckProductionBlockReason
    ) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    private var sortKey: String {
        switch self {
        case .fixtureOnly:
            return "0:fixture-only"
        case .missingRequiredFamily(let family):
            return "1:missing:\(family)"
        case .unsupportedRequiredFamily(let family, let reasonCode):
            return "2:unsupported-required:\(family):\(reasonCode)"
        case .unsupportedDirective(let reasonCode):
            return "3:unsupported:\(reasonCode)"
        }
    }
}
