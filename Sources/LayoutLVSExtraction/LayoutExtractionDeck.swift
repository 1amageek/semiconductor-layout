public struct LayoutExtractionDeck: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let processID: String
    public let processProfileID: String
    public let sourcePath: String
    public let sourceDigest: String
    public let useScope: LayoutExtractionDeckUseScope
    public let deviceRules: [LayoutExtractionDeviceRule]
    public let unsupportedDirectives: [LayoutExtractionUnsupportedDirective]

    public init(
        schemaVersion: Int = LayoutExtractionDeck.currentSchemaVersion,
        processID: String,
        processProfileID: String,
        sourcePath: String,
        sourceDigest: String,
        useScope: LayoutExtractionDeckUseScope,
        deviceRules: [LayoutExtractionDeviceRule],
        unsupportedDirectives: [LayoutExtractionUnsupportedDirective] = []
    ) {
        self.schemaVersion = schemaVersion
        self.processID = processID
        self.processProfileID = processProfileID
        self.sourcePath = sourcePath
        self.sourceDigest = sourceDigest
        self.useScope = useScope
        self.deviceRules = deviceRules.sorted { $0.ruleID < $1.ruleID }
        self.unsupportedDirectives = unsupportedDirectives
    }
}
