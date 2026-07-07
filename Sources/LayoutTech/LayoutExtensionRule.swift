import Foundation
import LayoutCore

/// Requires `extendingLayer` geometry to extend beyond `enclosedLayer`
/// geometry by `minExtension` along the selected axis.
public struct LayoutExtensionRule: Hashable, Sendable, Codable {
    public enum Direction: String, Hashable, Sendable, Codable {
        case horizontal
        case vertical
    }

    public var extendingLayer: LayoutLayerID
    public var enclosedLayer: LayoutLayerID
    public var minExtension: Double
    public var direction: Direction

    public init(
        extendingLayer: LayoutLayerID,
        enclosedLayer: LayoutLayerID,
        minExtension: Double,
        direction: Direction
    ) {
        self.extendingLayer = extendingLayer
        self.enclosedLayer = enclosedLayer
        self.minExtension = minExtension
        self.direction = direction
    }
}
