import LayoutCore

public enum LayoutExtractionParameterValueConvention: String, Sendable, Hashable, Codable {
    case spiceSI
    case micronScalar
}

public struct LayoutExtractionLayerReference: Sendable, Hashable, Codable {
    public let names: Set<String>

    public init(names: Set<String>) {
        self.names = Set(names.map { $0.lowercased() })
    }

    public func matches(_ layer: LayoutLayerID) -> Bool {
        names.contains(layer.name.lowercased())
    }
}

public struct LayoutExtractionConnectionRule: Sendable, Hashable, Codable {
    public let cutLayers: LayoutExtractionLayerReference
    public let lowerLayers: LayoutExtractionLayerReference
    public let upperLayers: LayoutExtractionLayerReference

    public init(
        cutLayers: LayoutExtractionLayerReference,
        lowerLayers: LayoutExtractionLayerReference,
        upperLayers: LayoutExtractionLayerReference
    ) {
        self.cutLayers = cutLayers
        self.lowerLayers = lowerLayers
        self.upperLayers = upperLayers
    }
}

public struct LayoutExtractionMOSRule: Sendable, Hashable, Codable {
    public let ruleID: String
    public let model: String
    public let gateLayers: LayoutExtractionLayerReference
    public let diffusionLayers: LayoutExtractionLayerReference
    public let selectorLayers: LayoutExtractionLayerReference
    public let exclusionLayers: LayoutExtractionLayerReference
    public let bulkLayers: LayoutExtractionLayerReference
    public let bulkTapLayers: LayoutExtractionLayerReference
    public let bulkTapSelectorLayers: LayoutExtractionLayerReference
    public let bulkPortCandidates: [String]
    public let preferNamedBulkPort: Bool
    public let sourceLocation: LayoutExtractionSourceLocation?

    public init(
        ruleID: String,
        model: String,
        gateLayers: LayoutExtractionLayerReference,
        diffusionLayers: LayoutExtractionLayerReference,
        selectorLayers: LayoutExtractionLayerReference,
        exclusionLayers: LayoutExtractionLayerReference = LayoutExtractionLayerReference(names: []),
        bulkLayers: LayoutExtractionLayerReference,
        bulkTapLayers: LayoutExtractionLayerReference = LayoutExtractionLayerReference(names: []),
        bulkTapSelectorLayers: LayoutExtractionLayerReference = LayoutExtractionLayerReference(names: []),
        bulkPortCandidates: [String],
        preferNamedBulkPort: Bool = false,
        sourceLocation: LayoutExtractionSourceLocation? = nil
    ) {
        self.ruleID = ruleID
        self.model = model
        self.gateLayers = gateLayers
        self.diffusionLayers = diffusionLayers
        self.selectorLayers = selectorLayers
        self.exclusionLayers = exclusionLayers
        self.bulkLayers = bulkLayers
        self.bulkTapLayers = bulkTapLayers
        self.bulkTapSelectorLayers = bulkTapSelectorLayers
        self.bulkPortCandidates = bulkPortCandidates
        self.preferNamedBulkPort = preferNamedBulkPort
        self.sourceLocation = sourceLocation
    }
}

public struct LayoutExtractionProcessProfile: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let processID: String
    public let processProfileID: String
    public let extractionDeckDigest: String
    public let deckUseScope: LayoutExtractionDeckUseScope
    public let parameterValueConvention: LayoutExtractionParameterValueConvention
    public let conductorLayers: LayoutExtractionLayerReference
    public let connectionRules: [LayoutExtractionConnectionRule]
    public let mosRules: [LayoutExtractionMOSRule]

    public init(
        schemaVersion: Int = LayoutExtractionProcessProfile.currentSchemaVersion,
        processID: String,
        processProfileID: String,
        extractionDeckDigest: String,
        deckUseScope: LayoutExtractionDeckUseScope,
        parameterValueConvention: LayoutExtractionParameterValueConvention = .spiceSI,
        conductorLayers: LayoutExtractionLayerReference,
        connectionRules: [LayoutExtractionConnectionRule],
        mosRules: [LayoutExtractionMOSRule]
    ) {
        self.schemaVersion = schemaVersion
        self.processID = processID
        self.processProfileID = processProfileID
        self.extractionDeckDigest = extractionDeckDigest
        self.deckUseScope = deckUseScope
        self.parameterValueConvention = parameterValueConvention
        self.conductorLayers = conductorLayers
        self.connectionRules = connectionRules
        self.mosRules = mosRules
    }
}
