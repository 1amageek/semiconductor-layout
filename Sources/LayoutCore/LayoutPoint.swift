import Foundation

public struct LayoutPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = LayoutPoint(x: 0, y: 0)

    public func translated(by other: LayoutPoint) -> LayoutPoint {
        LayoutPoint(x: x + other.x, y: y + other.y)
    }

    public func scaled(by scale: Double) -> LayoutPoint {
        LayoutPoint(x: x * scale, y: y * scale)
    }
}
