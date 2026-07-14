public enum LayoutExtractionDeckQualificationScope: String, Sendable, Hashable, Codable {
    case fixtureOnly
    case productionCandidate

    public var allowsProductionQualification: Bool {
        self == .productionCandidate
    }
}
