import Foundation
import LayoutCore

public struct LayoutAntennaRule: Hashable, Sendable, Codable {
    public var layerID: LayoutLayerID
    public var maxRatio: Double

    public init(layerID: LayoutLayerID, maxRatio: Double) {
        self.layerID = layerID
        self.maxRatio = maxRatio
    }
}
