public struct LayoutRuleCoverage: Hashable, Sendable, Codable {
    public let ruleID: String
    public let status: LayoutRuleCoverageStatus
    public let sourceRuleIDs: [String]
    public let programNodeIDs: [String]
    public let witnessCaseIDs: [String]
    public let rationale: String?

    public init(
        ruleID: String,
        status: LayoutRuleCoverageStatus,
        sourceRuleIDs: [String] = [],
        programNodeIDs: [String] = [],
        witnessCaseIDs: [String] = [],
        rationale: String? = nil
    ) {
        self.ruleID = ruleID
        self.status = status
        self.sourceRuleIDs = Array(Set(sourceRuleIDs)).sorted()
        self.programNodeIDs = Array(Set(programNodeIDs)).sorted()
        self.witnessCaseIDs = Array(Set(witnessCaseIDs)).sorted()
        self.rationale = rationale
    }
}
