/// Typed validation failures for exact-overlap design rules.
public enum LayoutExactOverlapRuleError: Error, Hashable, Sendable, CustomStringConvertible {
    case emptySecondaryLayers(ruleID: String)

    public var description: String {
        switch self {
        case .emptySecondaryLayers(let ruleID):
            return "Exact-overlap rule \(ruleID) requires at least one secondary layer."
        }
    }
}
