public struct LayoutExtractionBlackbox: Sendable, Hashable, Codable {
    public let id: LayoutExtractionObjectID
    public let model: String
    public let portNames: [String]
    public let occurrenceIDs: [LayoutExtractionObjectID]
    public let sourceLocation: LayoutExtractionSourceLocation?

    public init(
        id: LayoutExtractionObjectID,
        model: String,
        portNames: [String],
        occurrenceIDs: [LayoutExtractionObjectID],
        sourceLocation: LayoutExtractionSourceLocation? = nil
    ) {
        self.id = id
        self.model = model
        self.portNames = portNames
        self.occurrenceIDs = occurrenceIDs.sorted()
        self.sourceLocation = sourceLocation
    }
}
