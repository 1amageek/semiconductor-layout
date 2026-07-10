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
    public var layerGeometries: [LayoutViaLayerGeometry]

    public init(
        id: String,
        cutLayer: LayoutLayerID,
        topLayer: LayoutLayerID,
        bottomLayer: LayoutLayerID,
        cutSize: LayoutSize,
        enclosure: LayoutViaEnclosure,
        cutSpacing: Double,
        layerGeometries: [LayoutViaLayerGeometry] = []
    ) {
        self.id = id
        self.cutLayer = cutLayer
        self.topLayer = topLayer
        self.bottomLayer = bottomLayer
        self.cutSize = cutSize
        self.enclosure = enclosure
        self.cutSpacing = cutSpacing
        self.layerGeometries = layerGeometries
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case cutLayer
        case topLayer
        case bottomLayer
        case cutSize
        case enclosure
        case cutSpacing
        case layerGeometries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cutLayer = try container.decode(LayoutLayerID.self, forKey: .cutLayer)
        topLayer = try container.decode(LayoutLayerID.self, forKey: .topLayer)
        bottomLayer = try container.decode(LayoutLayerID.self, forKey: .bottomLayer)
        cutSize = try container.decode(LayoutSize.self, forKey: .cutSize)
        enclosure = try container.decode(LayoutViaEnclosure.self, forKey: .enclosure)
        cutSpacing = try container.decode(Double.self, forKey: .cutSpacing)
        layerGeometries = try container.decode(
            [LayoutViaLayerGeometry].self,
            forKey: .layerGeometries
        )
    }
}
