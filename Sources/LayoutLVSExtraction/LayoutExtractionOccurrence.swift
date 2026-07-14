public struct LayoutExtractionOccurrence: Sendable, Hashable, Codable {
    public let objectID: LayoutExtractionObjectID
    public let cellName: String
    public let hierarchyPath: [String]
    public let sourceObjectID: String?
    public let transformDescription: String

    public init(
        objectID: LayoutExtractionObjectID,
        cellName: String,
        hierarchyPath: [String],
        sourceObjectID: String? = nil,
        transformDescription: String
    ) {
        self.objectID = objectID
        self.cellName = cellName
        self.hierarchyPath = hierarchyPath
        self.sourceObjectID = sourceObjectID
        self.transformDescription = transformDescription
    }
}
