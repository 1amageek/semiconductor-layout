import Foundation
import LayoutCore

/// Antenna (plasma-induced gate-oxide damage) limit for one conductor layer.
///
/// `maxRatio` bounds the partial antenna ratio (PAR): the merged area of
/// this layer connected to a gate at this layer's etch stage, divided by
/// the connected gate area. `maxCumulativeRatio`, when set, additionally
/// bounds the cumulative antenna ratio (CAR): the sum of merged areas of
/// every antenna-rule layer fabricated up to and including this one,
/// divided by the same gate area.
public struct LayoutAntennaRule: Hashable, Sendable, Codable {
    public var layerID: LayoutLayerID
    public var maxRatio: Double
    public var maxCumulativeRatio: Double?

    public init(
        layerID: LayoutLayerID,
        maxRatio: Double,
        maxCumulativeRatio: Double? = nil
    ) {
        self.layerID = layerID
        self.maxRatio = maxRatio
        self.maxCumulativeRatio = maxCumulativeRatio
    }
}
