import Foundation

public struct FlattenInstanceCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let instanceID: UUID

    public init(cellID: UUID, instanceID: UUID) {
        self.cellID = cellID
        self.instanceID = instanceID
    }
}
