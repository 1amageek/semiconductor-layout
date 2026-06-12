import Foundation
import LayoutCore

/// One conductor member of an island as it actually sits in the edit
/// space: layer plus occurrence-exact bounding box.
///
/// `ConnectivityIsland.shapeIDs` alias across instance occurrences — a
/// child shape reused by several placements contributes ONE id but
/// several footprints — so geometry consumers (route landing zones,
/// markers) must use footprints, never id-resolved geometry.
public struct ConnectivityIslandFootprint: Equatable, Sendable {
    public let layer: LayoutLayerID
    public let boundingBox: LayoutRect

    public init(layer: LayoutLayerID, boundingBox: LayoutRect) {
        self.layer = layer
        self.boundingBox = boundingBox
    }
}
