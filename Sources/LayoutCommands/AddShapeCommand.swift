import Foundation
import LayoutCore

public struct AddShapeCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let shapeID: UUID
    public let layer: LayoutLayerID
    public let geometry: LayoutGeometry
    public let netID: UUID?
    public let properties: [String: String]

    public init(
        cellID: UUID,
        shapeID: UUID,
        layer: LayoutLayerID,
        geometry: LayoutGeometry,
        netID: UUID? = nil,
        properties: [String: String] = [:]
    ) {
        self.cellID = cellID
        self.shapeID = shapeID
        self.layer = layer
        self.geometry = geometry
        self.netID = netID
        self.properties = properties
    }
}
