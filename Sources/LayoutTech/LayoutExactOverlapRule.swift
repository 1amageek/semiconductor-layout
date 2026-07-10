import Foundation
import LayoutCore

/// Requires every primary-layer feature to have a secondary-layer feature
/// with matching bounds.
public struct LayoutExactOverlapRule: Hashable, Sendable, Codable {
    public var id: String
    public var primaryLayer: LayoutLayerID
    public var secondaryLayers: [LayoutLayerID]
    public var tolerance: Double

    public var secondaryLayer: LayoutLayerID {
        get { secondaryLayers[0] }
        set {
            if secondaryLayers.isEmpty {
                secondaryLayers = [newValue]
            } else {
                secondaryLayers[0] = newValue
            }
        }
    }

    public init(
        id: String,
        primaryLayer: LayoutLayerID,
        secondaryLayer: LayoutLayerID,
        tolerance: Double = 0
    ) {
        self.id = id
        self.primaryLayer = primaryLayer
        self.secondaryLayers = [secondaryLayer]
        self.tolerance = tolerance
    }

    public init(
        id: String,
        primaryLayer: LayoutLayerID,
        secondaryLayers: [LayoutLayerID],
        tolerance: Double = 0
    ) {
        self.id = id
        self.primaryLayer = primaryLayer
        self.secondaryLayers = secondaryLayers.isEmpty ? [primaryLayer] : secondaryLayers
        self.tolerance = tolerance
    }

    public init(
        validatingID id: String,
        primaryLayer: LayoutLayerID,
        secondaryLayers: [LayoutLayerID],
        tolerance: Double = 0
    ) throws {
        guard !secondaryLayers.isEmpty else {
            throw LayoutExactOverlapRuleError.emptySecondaryLayers(ruleID: id)
        }
        self.id = id
        self.primaryLayer = primaryLayer
        self.secondaryLayers = secondaryLayers
        self.tolerance = tolerance
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case primaryLayer
        case secondaryLayers
        case tolerance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.primaryLayer = try container.decode(LayoutLayerID.self, forKey: .primaryLayer)
        let decodedSecondaryLayers = try container.decode(
            [LayoutLayerID].self,
            forKey: .secondaryLayers
        )
        guard !decodedSecondaryLayers.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .secondaryLayers,
                in: container,
                debugDescription: LayoutExactOverlapRuleError.emptySecondaryLayers(ruleID: id).description
            )
        }
        self.secondaryLayers = decodedSecondaryLayers
        self.tolerance = try container.decode(Double.self, forKey: .tolerance)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(primaryLayer, forKey: .primaryLayer)
        try container.encode(secondaryLayers, forKey: .secondaryLayers)
        try container.encode(tolerance, forKey: .tolerance)
    }
}
