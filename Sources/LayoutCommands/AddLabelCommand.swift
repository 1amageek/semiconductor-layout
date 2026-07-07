import Foundation
import LayoutCore

public struct AddLabelCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let labelID: UUID
    public let text: String
    public let position: LayoutPoint
    public let layer: LayoutLayerID
    public let netID: UUID?

    public init(
        cellID: UUID,
        labelID: UUID,
        text: String,
        position: LayoutPoint,
        layer: LayoutLayerID,
        netID: UUID? = nil
    ) {
        self.cellID = cellID
        self.labelID = labelID
        self.text = text
        self.position = position
        self.layer = layer
        self.netID = netID
    }
}
