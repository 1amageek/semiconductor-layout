import Foundation

public struct LayoutPin: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var position: LayoutPoint
    public var size: LayoutSize
    public var layer: LayoutLayerID
    public var netID: UUID?
    public var role: LayoutPinRole

    public init(
        id: UUID = UUID(),
        name: String,
        position: LayoutPoint,
        size: LayoutSize,
        layer: LayoutLayerID,
        netID: UUID? = nil,
        role: LayoutPinRole = .signal
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.size = size
        self.layer = layer
        self.netID = netID
        self.role = role
    }

    /// Returns world extents; arbitrary-angle pins remain axis-aligned envelopes.
    public func transformed(by transforms: [LayoutTransform]) -> LayoutPin {
        guard !transforms.isEmpty else { return self }
        var result = self
        var geometry = LayoutGeometry.rect(LayoutRect(
            origin: LayoutPoint(x: position.x - size.width / 2, y: position.y - size.height / 2),
            size: size
        ))
        for transform in transforms.reversed() {
            result.position = transform.apply(to: result.position)
            geometry = geometry.transformed(by: transform)
        }
        result.size = LayoutGeometryAnalysis.boundingBox(for: geometry).size
        return result
    }
}
