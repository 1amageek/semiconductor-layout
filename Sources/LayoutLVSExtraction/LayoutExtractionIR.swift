public struct LayoutExtractionIR: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 5

    public let schemaVersion: Int
    public let processID: String
    public let processProfileID: String
    public let extractionDeckDigest: String
    public let deckUseScope: LayoutExtractionDeckUseScope
    public let parameterValueConvention: LayoutExtractionParameterValueConvention
    public let topCell: String
    public let devices: [LayoutExtractionDevice]
    public let nets: [LayoutExtractionNet]
    public let ports: [LayoutExtractionPort]
    public let occurrences: [LayoutExtractionOccurrence]
    public let blackboxes: [LayoutExtractionBlackbox]
    public let transformLedger: [LayoutExtractionTransformRecord]
    public let issues: [LayoutExtractionIssue]

    public init(
        schemaVersion: Int = LayoutExtractionIR.currentSchemaVersion,
        processID: String,
        processProfileID: String,
        extractionDeckDigest: String,
        deckUseScope: LayoutExtractionDeckUseScope,
        parameterValueConvention: LayoutExtractionParameterValueConvention = .spiceSI,
        topCell: String,
        devices: [LayoutExtractionDevice],
        nets: [LayoutExtractionNet],
        ports: [LayoutExtractionPort],
        occurrences: [LayoutExtractionOccurrence],
        blackboxes: [LayoutExtractionBlackbox] = [],
        transformLedger: [LayoutExtractionTransformRecord] = [],
        issues: [LayoutExtractionIssue] = []
    ) {
        self.schemaVersion = schemaVersion
        self.processID = processID
        self.processProfileID = processProfileID
        self.extractionDeckDigest = extractionDeckDigest
        self.deckUseScope = deckUseScope
        self.parameterValueConvention = parameterValueConvention
        self.topCell = topCell
        self.devices = devices.sorted { $0.id < $1.id }
        self.nets = nets.sorted { $0.id < $1.id }
        self.ports = ports.sorted { $0.position < $1.position }
        self.occurrences = occurrences.sorted { $0.objectID < $1.objectID }
        self.blackboxes = blackboxes.sorted { $0.id < $1.id }
        self.transformLedger = transformLedger.sorted { $0.transformID < $1.transformID }
        self.issues = issues
    }

    public var isReady: Bool {
        !issues.contains { $0.severity == .blocking }
    }
}
