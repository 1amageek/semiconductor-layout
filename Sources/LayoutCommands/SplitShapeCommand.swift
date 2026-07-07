import Foundation

public struct SplitShapeCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let shapeID: UUID
    public let firstShapeID: UUID
    public let secondShapeID: UUID
    public let axis: SplitShapeAxis
    public let coordinate: Double

    public init(
        cellID: UUID,
        shapeID: UUID,
        firstShapeID: UUID,
        secondShapeID: UUID,
        axis: SplitShapeAxis,
        coordinate: Double
    ) {
        self.cellID = cellID
        self.shapeID = shapeID
        self.firstShapeID = firstShapeID
        self.secondShapeID = secondShapeID
        self.axis = axis
        self.coordinate = coordinate
    }
}
