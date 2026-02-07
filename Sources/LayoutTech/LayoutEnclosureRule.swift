import Foundation
import LayoutCore

public struct LayoutEnclosureRule: Hashable, Sendable, Codable {
    public var outerLayer: LayoutLayerID
    public var innerLayer: LayoutLayerID
    public var minEnclosure: Double

    public init(
        outerLayer: LayoutLayerID,
        innerLayer: LayoutLayerID,
        minEnclosure: Double
    ) {
        self.outerLayer = outerLayer
        self.innerLayer = innerLayer
        self.minEnclosure = minEnclosure
    }
}
