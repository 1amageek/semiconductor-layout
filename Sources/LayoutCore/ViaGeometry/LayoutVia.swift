import Foundation

public struct LayoutVia: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var viaDefinitionID: String
    public var position: LayoutPoint
    public var netID: UUID?
    /// Outermost-first transforms of definition-local geometry, before placement translation.
    public let geometryTransforms: [LayoutTransform]

    public init(
        id: UUID = UUID(),
        viaDefinitionID: String,
        position: LayoutPoint,
        netID: UUID? = nil,
        geometryTransforms: [LayoutTransform] = []
    ) {
        self.id = id
        self.viaDefinitionID = viaDefinitionID
        self.position = position
        self.netID = netID
        self.geometryTransforms = geometryTransforms
    }

    /// Preserves the complete footprint when moving through an instance hierarchy.
    public func transformed(by transforms: [LayoutTransform]) -> LayoutVia {
        var transformedPosition = position
        for transform in transforms.reversed() {
            transformedPosition = transform.apply(to: transformedPosition)
        }
        let linearTransforms = transforms.compactMap { transform -> LayoutTransform? in
            if transform.rotationDegrees.truncatingRemainder(dividingBy: 360) == 0,
               transform.magnification == 1, !transform.mirrorX, !transform.mirrorY { return nil }
            var linear = transform
            linear.translation = .zero
            return linear
        }
        return LayoutVia(
            id: id, viaDefinitionID: viaDefinitionID, position: transformedPosition,
            netID: netID, geometryTransforms: linearTransforms + geometryTransforms
        )
    }

    public func geometry(forLocalRect rect: LayoutRect) -> LayoutGeometry {
        if geometryTransforms.isEmpty {
            return .rect(LayoutRect(origin: rect.origin.translated(by: position), size: rect.size))
        }
        var geometry = LayoutGeometry.rect(rect)
        for transform in geometryTransforms.reversed() {
            geometry = geometry.transformed(by: transform)
        }
        return geometry.transformed(by: LayoutTransform(translation: position))
    }
}
