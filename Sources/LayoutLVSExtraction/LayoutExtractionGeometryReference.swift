import LayoutCore

public struct LayoutExtractionGeometryReference: Sendable, Hashable, Codable {
    public let objectID: LayoutExtractionObjectID
    public let occurrenceID: LayoutExtractionObjectID
    public let sourceObjectID: String
    public let layer: LayoutLayerID
    public let bounds: LayoutRect

    public init(
        objectID: LayoutExtractionObjectID,
        occurrenceID: LayoutExtractionObjectID,
        sourceObjectID: String,
        layer: LayoutLayerID,
        bounds: LayoutRect
    ) {
        self.objectID = objectID
        self.occurrenceID = occurrenceID
        self.sourceObjectID = sourceObjectID
        self.layer = layer
        self.bounds = bounds
    }
}
