import Foundation
import LayoutCore

public struct LayoutLayerRuleSet: Hashable, Sendable, Codable {
    public var layerID: LayoutLayerID
    public var minWidth: Double
    public var minSpacing: Double
    public var minArea: Double
    public var minDensity: Double
    public var maxDensity: Double
    public var densityWindow: LayoutSize?
    public var densityStep: Double?
    public var maskColors: [String]
    /// Minimum notch width: same-component facing-edge gaps narrower than
    /// this are violations even when they satisfy `minSpacing`.
    public var minNotch: Double?
    /// Metal at least this wide is "wide metal" and must keep `wideSpacing`
    /// to all other geometry on the layer.
    public var wideWidthThreshold: Double?
    /// Spacing required from wide metal to any other geometry on the layer.
    public var wideSpacing: Double?
    /// Minimum area of a hole fully enclosed by geometry on this layer.
    public var minEnclosedArea: Double?

    public init(
        layerID: LayoutLayerID,
        minWidth: Double,
        minSpacing: Double,
        minArea: Double,
        minDensity: Double,
        maxDensity: Double,
        densityWindow: LayoutSize? = nil,
        densityStep: Double? = nil,
        maskColors: [String] = [],
        minNotch: Double? = nil,
        wideWidthThreshold: Double? = nil,
        wideSpacing: Double? = nil,
        minEnclosedArea: Double? = nil
    ) {
        self.layerID = layerID
        self.minWidth = minWidth
        self.minSpacing = minSpacing
        self.minArea = minArea
        self.minDensity = minDensity
        self.maxDensity = maxDensity
        self.densityWindow = densityWindow
        self.densityStep = densityStep
        self.maskColors = maskColors
        self.minNotch = minNotch
        self.wideWidthThreshold = wideWidthThreshold
        self.wideSpacing = wideSpacing
        self.minEnclosedArea = minEnclosedArea
    }
}
