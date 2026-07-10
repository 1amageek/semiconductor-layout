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
    /// Whether every shape on this layer must be an axis-aligned rectangle.
    public var requiresRectangular: Bool
    /// Allowed edge-angle increment in degrees. A value of 45 accepts
    /// 0/45/90/135 degree edges, while 90 accepts Manhattan edges only.
    public var allowedAngleStepDegrees: Double?

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
        minEnclosedArea: Double? = nil,
        requiresRectangular: Bool = false,
        allowedAngleStepDegrees: Double? = nil
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
        self.requiresRectangular = requiresRectangular
        self.allowedAngleStepDegrees = allowedAngleStepDegrees
    }

    private enum CodingKeys: String, CodingKey {
        case layerID
        case minWidth
        case minSpacing
        case minArea
        case minDensity
        case maxDensity
        case densityWindow
        case densityStep
        case maskColors
        case minNotch
        case wideWidthThreshold
        case wideSpacing
        case minEnclosedArea
        case requiresRectangular
        case allowedAngleStepDegrees
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layerID = try container.decode(LayoutLayerID.self, forKey: .layerID)
        minWidth = try container.decode(Double.self, forKey: .minWidth)
        minSpacing = try container.decode(Double.self, forKey: .minSpacing)
        minArea = try container.decode(Double.self, forKey: .minArea)
        minDensity = try container.decode(Double.self, forKey: .minDensity)
        maxDensity = try container.decode(Double.self, forKey: .maxDensity)
        densityWindow = try container.decodeIfPresent(LayoutSize.self, forKey: .densityWindow)
        densityStep = try container.decodeIfPresent(Double.self, forKey: .densityStep)
        maskColors = try container.decode([String].self, forKey: .maskColors)
        minNotch = try container.decodeIfPresent(Double.self, forKey: .minNotch)
        wideWidthThreshold = try container.decodeIfPresent(Double.self, forKey: .wideWidthThreshold)
        wideSpacing = try container.decodeIfPresent(Double.self, forKey: .wideSpacing)
        minEnclosedArea = try container.decodeIfPresent(Double.self, forKey: .minEnclosedArea)
        requiresRectangular = try container.decode(Bool.self, forKey: .requiresRectangular)
        allowedAngleStepDegrees = try container.decodeIfPresent(Double.self, forKey: .allowedAngleStepDegrees)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layerID, forKey: .layerID)
        try container.encode(minWidth, forKey: .minWidth)
        try container.encode(minSpacing, forKey: .minSpacing)
        try container.encode(minArea, forKey: .minArea)
        try container.encode(minDensity, forKey: .minDensity)
        try container.encode(maxDensity, forKey: .maxDensity)
        try container.encodeIfPresent(densityWindow, forKey: .densityWindow)
        try container.encodeIfPresent(densityStep, forKey: .densityStep)
        try container.encode(maskColors, forKey: .maskColors)
        try container.encodeIfPresent(minNotch, forKey: .minNotch)
        try container.encodeIfPresent(wideWidthThreshold, forKey: .wideWidthThreshold)
        try container.encodeIfPresent(wideSpacing, forKey: .wideSpacing)
        try container.encodeIfPresent(minEnclosedArea, forKey: .minEnclosedArea)
        try container.encode(requiresRectangular, forKey: .requiresRectangular)
        try container.encodeIfPresent(allowedAngleStepDegrees, forKey: .allowedAngleStepDegrees)
    }
}
