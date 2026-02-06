import Foundation
import LayoutCore

public struct LayoutViaDefinition: Hashable, Sendable, Codable {
    public var id: String
    public var cutLayer: LayoutLayerID
    public var topLayer: LayoutLayerID
    public var bottomLayer: LayoutLayerID
    public var cutSize: LayoutSize
    public var enclosure: LayoutViaEnclosure
    public var cutSpacing: Double

    public init(
        id: String,
        cutLayer: LayoutLayerID,
        topLayer: LayoutLayerID,
        bottomLayer: LayoutLayerID,
        cutSize: LayoutSize,
        enclosure: LayoutViaEnclosure,
        cutSpacing: Double
    ) {
        self.id = id
        self.cutLayer = cutLayer
        self.topLayer = topLayer
        self.bottomLayer = bottomLayer
        self.cutSize = cutSize
        self.enclosure = enclosure
        self.cutSpacing = cutSpacing
    }
}
