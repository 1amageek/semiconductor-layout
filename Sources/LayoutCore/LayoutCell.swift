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

    public init(
        id: UUID = UUID(),
        name: String,
        shapes: [LayoutShape] = [],
        vias: [LayoutVia] = [],
        labels: [LayoutLabel] = [],
        pins: [LayoutPin] = [],
        instances: [LayoutInstance] = [],
        nets: [LayoutNet] = [],
        constraints: [LayoutConstraint] = []
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
    }
}
