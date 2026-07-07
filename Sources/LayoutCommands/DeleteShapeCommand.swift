import Foundation

public struct DeleteShapeCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let shapeID: UUID

    public init(cellID: UUID, shapeID: UUID) {
        self.cellID = cellID
        self.shapeID = shapeID
    }
}
