import Foundation

public struct MakeCellCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let newCellID: UUID
    public let newInstanceID: UUID
    public let name: String
    public let instanceName: String
    public let shapeIDs: [UUID]
    public let instanceIDs: [UUID]

    public init(
        cellID: UUID,
        newCellID: UUID,
        newInstanceID: UUID,
        name: String,
        instanceName: String? = nil,
        shapeIDs: [UUID] = [],
        instanceIDs: [UUID] = []
    ) {
        self.cellID = cellID
        self.newCellID = newCellID
        self.newInstanceID = newInstanceID
        self.name = name
        self.instanceName = instanceName ?? name
        self.shapeIDs = shapeIDs
        self.instanceIDs = instanceIDs
    }
}
