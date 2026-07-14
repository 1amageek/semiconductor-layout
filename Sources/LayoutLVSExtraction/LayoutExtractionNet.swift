public struct LayoutExtractionNet: Sendable, Hashable, Codable {
    public let id: LayoutExtractionObjectID
    public let preferredName: String?
    public let occurrenceIDs: [LayoutExtractionObjectID]
    public let isGlobal: Bool
    public let geometryReferences: [LayoutExtractionGeometryReference]

    public init(
        id: LayoutExtractionObjectID,
        preferredName: String? = nil,
        occurrenceIDs: [LayoutExtractionObjectID],
        isGlobal: Bool = false,
        geometryReferences: [LayoutExtractionGeometryReference] = []
    ) {
        self.id = id
        self.preferredName = preferredName
        self.occurrenceIDs = occurrenceIDs.sorted()
        self.isGlobal = isGlobal
        self.geometryReferences = geometryReferences.sorted { $0.objectID < $1.objectID }
    }
}
