import Foundation
import LayoutCore

public struct AddRectCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let shapeID: UUID
    public let layer: LayoutLayerID
    public let origin: LayoutPoint
    public let size: LayoutSize
    public let netID: UUID?
    public let properties: [String: String]

    public init(
        cellID: UUID,
        shapeID: UUID,
        layer: LayoutLayerID,
        origin: LayoutPoint,
        size: LayoutSize,
        netID: UUID? = nil,
        properties: [String: String] = [:]
    ) {
        self.cellID = cellID
        self.shapeID = shapeID
        self.layer = layer
        self.origin = origin
        self.size = size
        self.netID = netID
        self.properties = properties
    }
}
