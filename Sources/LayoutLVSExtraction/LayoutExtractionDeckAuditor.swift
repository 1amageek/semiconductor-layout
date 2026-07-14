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
        var blockingReasons = missing.map(
            LayoutExtractionDeckProductionBlockReason.missingRequiredFamily
        )
        if deck.qualificationScope == .fixtureOnly {
            blockingReasons.append(.fixtureOnly)
        }
        for directive in deck.unsupportedDirectives {
            if let family = directive.family, requiredFamilies.contains(family) {
                blockingReasons.append(.unsupportedRequiredFamily(
                    family: family,
                    reasonCode: directive.reasonCode
                ))
            }
        }
        let productionEligibility = LayoutExtractionDeckProductionEligibility(
            blockingReasons: blockingReasons
        )
        return LayoutExtractionDeckAudit(
            status: productionEligibility.isEligible ? .satisfied : .blocked,
            processID: deck.processID,
            processProfileID: deck.processProfileID,
            sourceDigest: deck.sourceDigest,
            qualificationScope: deck.qualificationScope,
            productionEligibility: productionEligibility,
            deviceRuleCount: deck.deviceRules.count,
            deviceRuleCountsByFamily: counts,
            missingRequiredFamilies: missing,
            unsupportedRequiredFamilies: unsupportedRequiredFamilies,
            unsupportedDirectiveCount: deck.unsupportedDirectives.count
        )
    }
}
