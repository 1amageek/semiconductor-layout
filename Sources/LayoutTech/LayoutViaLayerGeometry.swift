import Foundation
import LayoutCore

public struct LayoutViaLayerGeometry: Hashable, Sendable, Codable {
    public var layer: LayoutLayerID
    public var rects: [LayoutRect]

    public init(layer: LayoutLayerID, rects: [LayoutRect] = []) {
        self.layer = layer
        self.rects = rects
    }
}
