import Foundation
import LayoutCore

public struct LayoutLayerRuleSet: Hashable, Sendable, Codable {
    public var layerID: LayoutLayerID
    public var minWidth: Double
    public var minSpacing: Double
    public var minArea: Double
    public var minDensity: Double
    public var maxDensity: Double
    public var maskColors: [String]

    public init(
        layerID: LayoutLayerID,
        minWidth: Double,
        minSpacing: Double,
        minArea: Double,
        minDensity: Double,
        maxDensity: Double,
        maskColors: [String] = []
    ) {
        self.layerID = layerID
        self.minWidth = minWidth
        self.minSpacing = minSpacing
        self.minArea = minArea
        self.minDensity = minDensity
        self.maxDensity = maxDensity
        self.maskColors = maskColors
    }
}
