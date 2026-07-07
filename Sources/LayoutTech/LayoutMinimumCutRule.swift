import Foundation
import LayoutCore

/// Requires at least `minimumCount` cut features between two conductor layers.
///
/// The rule is evaluated where same-net geometry on `bottomLayer` and
/// `topLayer` overlaps. Matching `LayoutVia` instances and explicit shapes
/// on `cutLayer` count as cut features when they intersect the overlap.
public struct LayoutMinimumCutRule: Hashable, Sendable, Codable {
    public var id: String
    public var cutLayer: LayoutLayerID
    public var bottomLayer: LayoutLayerID
    public var topLayer: LayoutLayerID
    public var minimumCount: Int

    public init(
        id: String,
        cutLayer: LayoutLayerID,
        bottomLayer: LayoutLayerID,
        topLayer: LayoutLayerID,
        minimumCount: Int
    ) {
        self.id = id
        self.cutLayer = cutLayer
        self.bottomLayer = bottomLayer
        self.topLayer = topLayer
        self.minimumCount = minimumCount
    }
}
