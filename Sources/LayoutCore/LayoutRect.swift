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

    /// Converts this rectangle to a 4-vertex polygon (CCW winding).
    public func toPolygon() -> LayoutPolygon {
        LayoutPolygon(points: [
            LayoutPoint(x: minX, y: minY),
            LayoutPoint(x: maxX, y: minY),
            LayoutPoint(x: maxX, y: maxY),
            LayoutPoint(x: minX, y: maxY),
        ])
    }

    // MARK: - Boolean Operations

    /// Subtracts `cut` from this rectangle, returning 0–4 non-overlapping remainder rectangles.
    ///
    /// ```
    /// +-------------------+
    /// |       TOP         |
    /// +-----+-------+-----+
    /// | LEFT|  cut  |RIGHT |
    /// +-----+-------+-----+
    /// |      BOTTOM       |
    /// +-------------------+
    /// ```
    public func subtract(cut: LayoutRect) -> [LayoutRect] {
        let ixMin = Swift.max(minX, cut.minX)
        let ixMax = Swift.min(maxX, cut.maxX)
        let iyMin = Swift.max(minY, cut.minY)
        let iyMax = Swift.min(maxY, cut.maxY)

        guard ixMin < ixMax, iyMin < iyMax else { return [self] }

        var results: [LayoutRect] = []

        // Bottom strip (full width)
        if iyMin > minY {
            results.append(LayoutRect(
                origin: LayoutPoint(x: minX, y: minY),
                size: LayoutSize(width: size.width, height: iyMin - minY)
            ))
        }
        // Top strip (full width)
        if iyMax < maxY {
            results.append(LayoutRect(
                origin: LayoutPoint(x: minX, y: iyMax),
                size: LayoutSize(width: size.width, height: maxY - iyMax)
            ))
        }
        // Left strip (between iyMin and iyMax)
        if ixMin > minX {
            results.append(LayoutRect(
                origin: LayoutPoint(x: minX, y: iyMin),
                size: LayoutSize(width: ixMin - minX, height: iyMax - iyMin)
            ))
        }
        // Right strip (between iyMin and iyMax)
        if ixMax < maxX {
            results.append(LayoutRect(
                origin: LayoutPoint(x: ixMax, y: iyMin),
                size: LayoutSize(width: maxX - ixMax, height: iyMax - iyMin)
            ))
        }

        return results
    }

    /// Splits this rectangle vertically at the given x coordinate.
    /// Returns `(left, right)` or `nil` if x is outside the rect.
    public func splitVertically(at x: Double) -> (LayoutRect, LayoutRect)? {
        guard x > minX, x < maxX else { return nil }
        let left = LayoutRect(
            origin: origin,
            size: LayoutSize(width: x - minX, height: size.height)
        )
        let right = LayoutRect(
            origin: LayoutPoint(x: x, y: origin.y),
            size: LayoutSize(width: maxX - x, height: size.height)
        )
        return (left, right)
    }

    /// Splits this rectangle horizontally at the given y coordinate.
    /// Returns `(bottom, top)` or `nil` if y is outside the rect.
    public func splitHorizontally(at y: Double) -> (LayoutRect, LayoutRect)? {
        guard y > minY, y < maxY else { return nil }
        let bottom = LayoutRect(
            origin: origin,
            size: LayoutSize(width: size.width, height: y - minY)
        )
        let top = LayoutRect(
            origin: LayoutPoint(x: origin.x, y: y),
            size: LayoutSize(width: size.width, height: maxY - y)
        )
        return (bottom, top)
    }
}
