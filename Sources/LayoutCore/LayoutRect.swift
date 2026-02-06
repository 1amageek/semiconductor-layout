import Foundation

public struct LayoutRect: Hashable, Sendable, Codable {
    public var origin: LayoutPoint
    public var size: LayoutSize

    public init(origin: LayoutPoint, size: LayoutSize) {
        self.origin = origin
        self.size = size
    }

    public static let zero = LayoutRect(origin: .zero, size: .zero)

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var center: LayoutPoint {
        LayoutPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    public func contains(_ point: LayoutPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func intersects(_ other: LayoutRect) -> Bool {
        !(other.maxX < minX || other.minX > maxX || other.maxY < minY || other.minY > maxY)
    }

    public func union(_ other: LayoutRect) -> LayoutRect {
        let minX = min(self.minX, other.minX)
        let minY = min(self.minY, other.minY)
        let maxX = max(self.maxX, other.maxX)
        let maxY = max(self.maxY, other.maxY)
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    public func inset(by dx: Double, _ dy: Double) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(x: origin.x + dx, y: origin.y + dy),
            size: LayoutSize(width: max(0, size.width - 2 * dx), height: max(0, size.height - 2 * dy))
        )
    }

    public func expanded(by dx: Double, _ dy: Double) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(x: origin.x - dx, y: origin.y - dy),
            size: LayoutSize(width: size.width + 2 * dx, height: size.height + 2 * dy)
        )
    }
}
