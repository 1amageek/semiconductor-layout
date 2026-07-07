import Foundation
import LayoutCore

public enum InstanceMirrorAxis: String, Codable, Sendable, Equatable {
    case x
    case y
    case vertical
    case horizontal
}

public struct MirrorInstanceCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let instanceID: UUID
    public let axis: InstanceMirrorAxis
    public let origin: LayoutPoint?

    public init(
        cellID: UUID,
        instanceID: UUID,
        axis: InstanceMirrorAxis,
        origin: LayoutPoint? = nil
    ) {
        self.cellID = cellID
        self.instanceID = instanceID
        self.axis = axis
        self.origin = origin
    }
}
