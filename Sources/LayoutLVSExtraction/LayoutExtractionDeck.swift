public struct LayoutExtractionDeck: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let processID: String
    public let processProfileID: String
    public let sourcePath: String
    public let sourceDigest: String
    public let qualificationScope: LayoutExtractionDeckQualificationScope
    public let deviceRules: [LayoutExtractionDeviceRule]
    public let unsupportedDirectives: [LayoutExtractionUnsupportedDirective]

    public init(
        schemaVersion: Int = LayoutExtractionDeck.currentSchemaVersion,
        processID: String,
        processProfileID: String,
        sourcePath: String,
        sourceDigest: String,
        qualificationScope: LayoutExtractionDeckQualificationScope = .productionCandidate,
        deviceRules: [LayoutExtractionDeviceRule],
        unsupportedDirectives: [LayoutExtractionUnsupportedDirective] = []
    ) {
        self.schemaVersion = schemaVersion
        self.processID = processID
        self.processProfileID = processProfileID
        self.sourcePath = sourcePath
        self.sourceDigest = sourceDigest
        self.qualificationScope = qualificationScope
        self.deviceRules = deviceRules.sorted { $0.ruleID < $1.ruleID }
        self.unsupportedDirectives = unsupportedDirectives
    }
}
