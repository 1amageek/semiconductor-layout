public struct LayoutExtractionDevice: Sendable, Hashable, Codable {
    public let id: LayoutExtractionObjectID
    public let model: String
    public let family: String
    public let terminals: [LayoutExtractionTerminal]
    public let parameters: [String: String]
    public let typedParameters: [LayoutExtractionTypedParameter]
    public let geometryReferences: [LayoutExtractionGeometryReference]
    public let occurrenceIDs: [LayoutExtractionObjectID]
    public let deckRuleID: String

    public init(
        id: LayoutExtractionObjectID,
        model: String,
        family: String,
        terminals: [LayoutExtractionTerminal],
        parameters: [String: String] = [:],
        typedParameters: [LayoutExtractionTypedParameter] = [],
        geometryReferences: [LayoutExtractionGeometryReference] = [],
        occurrenceIDs: [LayoutExtractionObjectID],
        deckRuleID: String
    ) {
        self.id = id
        self.model = model
        self.family = family
        self.terminals = terminals.sorted { $0.index < $1.index }
        self.parameters = parameters
        self.typedParameters = typedParameters.sorted { $0.name < $1.name }
        self.geometryReferences = geometryReferences.sorted { $0.objectID < $1.objectID }
        self.occurrenceIDs = occurrenceIDs.sorted()
        self.deckRuleID = deckRuleID
    }
}
