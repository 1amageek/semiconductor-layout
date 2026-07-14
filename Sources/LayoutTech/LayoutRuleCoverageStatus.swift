public enum LayoutRuleCoverageStatus: String, Hashable, Sendable, Codable {
    case implemented
    case delegated
    case manual
    case unsupported
    case notApplicable = "not-applicable"
}
