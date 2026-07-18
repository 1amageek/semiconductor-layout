public struct LayoutExtractionDeckAudit: Sendable, Hashable, Codable {
    public let processID: String
    public let processProfileID: String
    public let sourceDigest: String
    public let useScope: LayoutExtractionDeckUseScope
    public let semanticReadiness: LayoutExtractionDeckSemanticReadiness
    public let deviceRuleCount: Int
    public let deviceRuleCountsByFamily: [String: Int]
    public let missingRequiredFamilies: [String]
    public let unsupportedRequiredFamilies: [String]
    public let unsupportedDirectiveCount: Int

    public init(
        processID: String,
        processProfileID: String,
        sourceDigest: String,
        useScope: LayoutExtractionDeckUseScope,
        semanticReadiness: LayoutExtractionDeckSemanticReadiness,
        deviceRuleCount: Int,
        deviceRuleCountsByFamily: [String: Int],
        missingRequiredFamilies: [String],
        unsupportedRequiredFamilies: [String],
        unsupportedDirectiveCount: Int
    ) {
        self.processID = processID
        self.processProfileID = processProfileID
        self.sourceDigest = sourceDigest
        self.useScope = useScope
        self.semanticReadiness = semanticReadiness
        self.deviceRuleCount = deviceRuleCount
        self.deviceRuleCountsByFamily = deviceRuleCountsByFamily
        self.missingRequiredFamilies = missingRequiredFamilies.sorted()
        self.unsupportedRequiredFamilies = unsupportedRequiredFamilies.sorted()
        self.unsupportedDirectiveCount = unsupportedDirectiveCount
    }

    public var isReady: Bool {
        semanticReadiness.isReady
    }
}
