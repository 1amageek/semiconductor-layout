import Foundation

public struct LayoutTransform: Hashable, Sendable, Codable {
    public var translation: LayoutPoint
    public var rotation: LayoutRotation
    public var mirrorX: Bool
    public var mirrorY: Bool

    public init(
        translation: LayoutPoint = .zero,
        rotation: LayoutRotation = .deg0,
        mirrorX: Bool = false,
        mirrorY: Bool = false
    ) {
        self.translation = translation
        self.rotation = rotation
        self.mirrorX = mirrorX
        self.mirrorY = mirrorY
    }

    public func apply(to point: LayoutPoint) -> LayoutPoint {
        var x = point.x
        var y = point.y

        if mirrorX { x = -x }
        if mirrorY { y = -y }

        let rotated: LayoutPoint
        switch rotation {
        case .deg0:
            rotated = LayoutPoint(x: x, y: y)
        case .deg90:
            rotated = LayoutPoint(x: -y, y: x)
        case .deg180:
            rotated = LayoutPoint(x: -x, y: -y)
        case .deg270:
            rotated = LayoutPoint(x: y, y: -x)
        }

        return rotated.translated(by: translation)
    }
}
