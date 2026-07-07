import Foundation
import LayoutCore

public struct RotateInstanceCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let instanceID: UUID
    public let deltaDegrees: Double
    public let pivot: LayoutPoint?

    public init(
        cellID: UUID,
        instanceID: UUID,
        deltaDegrees: Double,
        pivot: LayoutPoint? = nil
    ) {
        self.cellID = cellID
        self.instanceID = instanceID
        self.deltaDegrees = deltaDegrees
        self.pivot = pivot
    }
}
