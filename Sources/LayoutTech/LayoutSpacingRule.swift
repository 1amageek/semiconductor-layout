import Foundation
import LayoutCore

/// Requires geometry on `primaryLayer` to keep `minSpacing` from geometry on
/// `secondaryLayer`.
public struct LayoutSpacingRule: Hashable, Sendable, Codable {
    public var id: String
    public var primaryLayer: LayoutLayerID
    public var secondaryLayer: LayoutLayerID
    public var minSpacing: Double

    public init(
        id: String,
        primaryLayer: LayoutLayerID,
        secondaryLayer: LayoutLayerID,
        minSpacing: Double
    ) {
        self.id = id
        self.primaryLayer = primaryLayer
        self.secondaryLayer = secondaryLayer
        self.minSpacing = minSpacing
    }
}
