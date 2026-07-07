import Foundation
import LayoutCore

public struct TranslateShapeCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let shapeID: UUID
    public let delta: LayoutPoint

    public init(cellID: UUID, shapeID: UUID, delta: LayoutPoint) {
        self.cellID = cellID
        self.shapeID = shapeID
        self.delta = delta
    }
}
