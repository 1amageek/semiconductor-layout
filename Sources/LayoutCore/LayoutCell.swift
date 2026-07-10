import Foundation

public struct LayoutCell: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var shapes: [LayoutShape]
    public var vias: [LayoutVia]
    public var labels: [LayoutLabel]
    public var pins: [LayoutPin]
    public var instances: [LayoutInstance]
    public var nets: [LayoutNet]
    public var constraints: [LayoutConstraint]
    public var properties: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        shapes: [LayoutShape] = [],
        vias: [LayoutVia] = [],
        labels: [LayoutLabel] = [],
        pins: [LayoutPin] = [],
        instances: [LayoutInstance] = [],
        nets: [LayoutNet] = [],
        constraints: [LayoutConstraint] = [],
        properties: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.shapes = shapes
        self.vias = vias
        self.labels = labels
        self.pins = pins
        self.instances = instances
        self.nets = nets
        self.constraints = constraints
        self.properties = properties
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case shapes
        case vias
        case labels
        case pins
        case instances
        case nets
        case constraints
        case properties
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        shapes = try container.decode([LayoutShape].self, forKey: .shapes)
        vias = try container.decode([LayoutVia].self, forKey: .vias)
        labels = try container.decode([LayoutLabel].self, forKey: .labels)
        pins = try container.decode([LayoutPin].self, forKey: .pins)
        instances = try container.decode([LayoutInstance].self, forKey: .instances)
        nets = try container.decode([LayoutNet].self, forKey: .nets)
        constraints = try container.decode([LayoutConstraint].self, forKey: .constraints)
        properties = try container.decode([String: String].self, forKey: .properties)
    }
}
