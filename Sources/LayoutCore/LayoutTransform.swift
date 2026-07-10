import Foundation

public struct LayoutTransform: Hashable, Sendable, Codable {
    public var translation: LayoutPoint
    public var rotationDegrees: Double
    public var magnification: Double
    public var mirrorX: Bool
    public var mirrorY: Bool

    public var rotation: LayoutRotation {
        get { LayoutRotation(nearestTo: rotationDegrees) }
        set { rotationDegrees = newValue.degrees }
    }

    public init(
        translation: LayoutPoint = .zero,
        rotation: LayoutRotation = .deg0,
        rotationDegrees: Double? = nil,
        magnification: Double = 1.0,
        mirrorX: Bool = false,
        mirrorY: Bool = false
    ) {
        self.translation = translation
        self.rotationDegrees = rotationDegrees ?? rotation.degrees
        self.magnification = magnification
        self.mirrorX = mirrorX
        self.mirrorY = mirrorY
    }

    public func apply(to point: LayoutPoint) -> LayoutPoint {
        var x = point.x
        var y = point.y

        if mirrorX { x = -x }
        if mirrorY { y = -y }
        x *= magnification
        y *= magnification

        let radians = rotationDegrees * .pi / 180
        let rotated = LayoutPoint(
            x: normalized(x * cos(radians) - y * sin(radians)),
            y: normalized(x * sin(radians) + y * cos(radians))
        )

        return rotated.translated(by: translation)
    }

    /// Maps a parent-space point back into the instance's local space.
    public func inverseApply(to point: LayoutPoint) throws -> LayoutPoint {
        try checkedInverseApply(to: point)
    }

    /// Maps a parent-space point back into the instance's local space with typed validation.
    public func checkedInverseApply(to point: LayoutPoint) throws -> LayoutPoint {
        guard magnification != 0 else {
            throw LayoutCoreError.nonInvertibleTransform(magnification: magnification)
        }
        let tx = point.x - translation.x
        let ty = point.y - translation.y

        let radians = -rotationDegrees * .pi / 180
        var x = normalized(tx * cos(radians) - ty * sin(radians))
        var y = normalized(tx * sin(radians) + ty * cos(radians))

        x /= magnification
        y /= magnification
        if mirrorX { x = -x }
        if mirrorY { y = -y }
        return LayoutPoint(x: x, y: y)
    }

    private enum CodingKeys: String, CodingKey {
        case translation
        case rotationDegrees
        case magnification
        case mirrorX
        case mirrorY
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        translation = try container.decode(LayoutPoint.self, forKey: .translation)
        rotationDegrees = try container.decode(Double.self, forKey: .rotationDegrees)
        magnification = try container.decode(Double.self, forKey: .magnification)
        mirrorX = try container.decode(Bool.self, forKey: .mirrorX)
        mirrorY = try container.decode(Bool.self, forKey: .mirrorY)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(translation, forKey: .translation)
        try container.encode(rotationDegrees, forKey: .rotationDegrees)
        try container.encode(magnification, forKey: .magnification)
        try container.encode(mirrorX, forKey: .mirrorX)
        try container.encode(mirrorY, forKey: .mirrorY)
    }

    private func normalized(_ value: Double) -> Double {
        abs(value) < 1e-12 ? 0 : value
    }
}
