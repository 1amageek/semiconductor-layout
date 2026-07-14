public struct LayoutExtractionPort: Sendable, Hashable, Codable {
    public let name: String
    public let position: Int
    public let netID: LayoutExtractionObjectID
    public let occurrenceIDs: [LayoutExtractionObjectID]

    public init(
        name: String,
        position: Int,
        netID: LayoutExtractionObjectID,
        occurrenceIDs: [LayoutExtractionObjectID]
    ) {
        self.name = name
        self.position = position
        self.netID = netID
        self.occurrenceIDs = occurrenceIDs.sorted()
    }
}
