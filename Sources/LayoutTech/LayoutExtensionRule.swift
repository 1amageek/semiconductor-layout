import Foundation
import LayoutCore

/// Requires `extendingLayer` geometry to extend beyond `enclosedLayer`
/// geometry by `minExtension` along the selected axis.
public struct LayoutExtensionRule: Hashable, Sendable, Codable {
    public enum Direction: String, Hashable, Sendable, Codable {
        case horizontal
        case vertical
    }

    public enum CoveragePolicy: String, Hashable, Sendable, Codable {
        /// Every enclosed shape must be covered by a qualifying extending shape.
        case required
        /// Extension is checked only where both layer geometries are present.
        case whenPresent = "when-present"
    }

    public var extendingLayer: LayoutLayerID
    public var enclosedLayer: LayoutLayerID
    public var minExtension: Double
    public var direction: Direction
    public var coveragePolicy: CoveragePolicy

    public init(
        extendingLayer: LayoutLayerID,
        enclosedLayer: LayoutLayerID,
        minExtension: Double,
        direction: Direction,
        coveragePolicy: CoveragePolicy = .required
    ) {
        self.extendingLayer = extendingLayer
        self.enclosedLayer = enclosedLayer
        self.minExtension = minExtension
        self.direction = direction
        self.coveragePolicy = coveragePolicy
    }

    private enum CodingKeys: String, CodingKey {
        case extendingLayer
        case enclosedLayer
        case minExtension
        case direction
        case coveragePolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extendingLayer = try container.decode(LayoutLayerID.self, forKey: .extendingLayer)
        enclosedLayer = try container.decode(LayoutLayerID.self, forKey: .enclosedLayer)
        minExtension = try container.decode(Double.self, forKey: .minExtension)
        direction = try container.decode(Direction.self, forKey: .direction)
        coveragePolicy = try container.decodeIfPresent(
            CoveragePolicy.self,
            forKey: .coveragePolicy
        ) ?? .required
    }
}
