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

    private enum CodingKeys: String, CodingKey {
        case translation
        case rotation
        case rotationDegrees
        case magnification
        case mirrorX
        case mirrorY
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        translation = try container.decodeIfPresent(LayoutPoint.self, forKey: .translation) ?? .zero
        if let exactRotation = try container.decodeIfPresent(Double.self, forKey: .rotationDegrees) {
            rotationDegrees = exactRotation
        } else {
            let legacyRotation = try container.decodeIfPresent(LayoutRotation.self, forKey: .rotation) ?? .deg0
            rotationDegrees = legacyRotation.degrees
        }
        magnification = try container.decodeIfPresent(Double.self, forKey: .magnification) ?? 1.0
        mirrorX = try container.decodeIfPresent(Bool.self, forKey: .mirrorX) ?? false
        mirrorY = try container.decodeIfPresent(Bool.self, forKey: .mirrorY) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(translation, forKey: .translation)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(rotationDegrees, forKey: .rotationDegrees)
        try container.encode(magnification, forKey: .magnification)
        try container.encode(mirrorX, forKey: .mirrorX)
        try container.encode(mirrorY, forKey: .mirrorY)
    }

    private func normalized(_ value: Double) -> Double {
        abs(value) < 1e-12 ? 0 : value
    }
}
