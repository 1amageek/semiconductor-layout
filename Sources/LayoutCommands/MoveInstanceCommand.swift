import Foundation
import LayoutCore

public struct MoveInstanceCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let instanceID: UUID
    public let delta: LayoutPoint

    public init(cellID: UUID, instanceID: UUID, delta: LayoutPoint) {
        self.cellID = cellID
        self.instanceID = instanceID
        self.delta = delta
    }
}
