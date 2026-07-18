public struct LayoutExtractionDeckAuditor: Sendable {
    public init() {}

    public func audit(
        _ deck: LayoutExtractionDeck,
        requiredFamilies: Set<String>
    ) -> LayoutExtractionDeckAudit {
        let counts = Dictionary(grouping: deck.deviceRules, by: \.family).mapValues(\.count)
        let missing = requiredFamilies.subtracting(counts.keys).sorted()
        let unsupportedRequiredFamilies = Set<String>(deck.unsupportedDirectives.compactMap { directive in
            guard let family = directive.family, requiredFamilies.contains(family) else {
                return nil
            }
            return family
        }).sorted()
        var semanticIssues = missing.map(
            LayoutExtractionDeckSemanticIssue.missingRequiredFamily
        )
        for directive in deck.unsupportedDirectives {
            if let family = directive.family, requiredFamilies.contains(family) {
                semanticIssues.append(.unsupportedRequiredFamily(
                    family: family,
                    reasonCode: directive.reasonCode
                ))
            }
        }
        let semanticReadiness = LayoutExtractionDeckSemanticReadiness(
            issues: semanticIssues
        )
        return LayoutExtractionDeckAudit(
            processID: deck.processID,
            processProfileID: deck.processProfileID,
            sourceDigest: deck.sourceDigest,
            useScope: deck.useScope,
            semanticReadiness: semanticReadiness,
            deviceRuleCount: deck.deviceRules.count,
            deviceRuleCountsByFamily: counts,
            missingRequiredFamilies: missing,
            unsupportedRequiredFamilies: unsupportedRequiredFamilies,
            unsupportedDirectiveCount: deck.unsupportedDirectives.count
        )
    }
}
