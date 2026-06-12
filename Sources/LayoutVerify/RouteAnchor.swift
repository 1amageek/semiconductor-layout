import Foundation
import LayoutCore

public struct RouteAnchor: Hashable, Sendable {
    public var point: LayoutPoint
    public var layer: LayoutLayerID
    public var netID: UUID?

    public init(point: LayoutPoint, layer: LayoutLayerID, netID: UUID? = nil) {
        self.point = point
        self.layer = layer
        self.netID = netID
    }
}
