public struct LayoutExtractionDeckAudit: Sendable, Hashable, Codable {
    public let status: LayoutExtractionDeckAuditStatus
    public let processID: String
    public let processProfileID: String
    public let sourceDigest: String
    public let qualificationScope: LayoutExtractionDeckQualificationScope
    public let productionEligibility: LayoutExtractionDeckProductionEligibility
    public let deviceRuleCount: Int
    public let deviceRuleCountsByFamily: [String: Int]
    public let missingRequiredFamilies: [String]
    public let unsupportedRequiredFamilies: [String]
    public let unsupportedDirectiveCount: Int

    public init(
        status: LayoutExtractionDeckAuditStatus,
        processID: String,
        processProfileID: String,
        sourceDigest: String,
        qualificationScope: LayoutExtractionDeckQualificationScope,
        productionEligibility: LayoutExtractionDeckProductionEligibility,
        deviceRuleCount: Int,
        deviceRuleCountsByFamily: [String: Int],
        missingRequiredFamilies: [String],
        unsupportedRequiredFamilies: [String],
        unsupportedDirectiveCount: Int
    ) {
        self.status = status
        self.processID = processID
        self.processProfileID = processProfileID
        self.sourceDigest = sourceDigest
        self.qualificationScope = qualificationScope
        self.productionEligibility = productionEligibility
        self.deviceRuleCount = deviceRuleCount
        self.deviceRuleCountsByFamily = deviceRuleCountsByFamily
        self.missingRequiredFamilies = missingRequiredFamilies.sorted()
        self.unsupportedRequiredFamilies = unsupportedRequiredFamilies.sorted()
        self.unsupportedDirectiveCount = unsupportedDirectiveCount
    }
}
