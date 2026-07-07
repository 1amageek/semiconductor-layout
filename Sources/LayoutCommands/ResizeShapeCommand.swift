import Foundation
import LayoutCore

public struct ResizeShapeCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let shapeID: UUID
    public let deltaMinX: Double
    public let deltaMinY: Double
    public let deltaMaxX: Double
    public let deltaMaxY: Double

    public init(
        cellID: UUID,
        shapeID: UUID,
        deltaMinX: Double,
        deltaMinY: Double,
        deltaMaxX: Double,
        deltaMaxY: Double
    ) {
        self.cellID = cellID
        self.shapeID = shapeID
        self.deltaMinX = deltaMinX
        self.deltaMinY = deltaMinY
        self.deltaMaxX = deltaMaxX
        self.deltaMaxY = deltaMaxY
    }
}
