import Foundation

public struct LayoutPath: Hashable, Sendable, Codable {
    public var points: [LayoutPoint]
    public var width: Double
    public var endCap: LayoutPathEndCap

    public init(points: [LayoutPoint], width: Double, endCap: LayoutPathEndCap = .extend) {
        self.points = points
        self.width = width
        self.endCap = endCap
    }

    public var isValid: Bool {
        points.count >= 2 && width.isFinite && width > 0 && endCap.isValid
            && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    /// Signed distances along the first and last segment, before grid admission.
    public func flatEndpointExtensions() throws(LayoutPathGeometryError) -> (begin: Double, end: Double) {
        guard isValid else { throw .invalidValue }
        let distances: (begin: Double, end: Double)
        switch endCap {
        case .truncate: distances = (0, 0)
        case .extend: distances = (width / 2, width / 2)
        case .round: throw .unsupportedCircularOutline
        case .custom(let begin, let end): distances = (begin, end)
        }
        let firstLength = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
        let lastLength = hypot(points[points.count - 1].x - points[points.count - 2].x,
                               points[points.count - 1].y - points[points.count - 2].y)
        guard firstLength.isFinite, lastLength.isFinite, firstLength > 0, lastLength > 0 else { throw .degenerateSegment }
        guard distances.begin > -firstLength, distances.end > -lastLength,
              points.count != 2 || firstLength + distances.begin + distances.end > 0 else {
            throw .invalidRetraction
        }
        return distances
    }

    /// A straight orthogonal stroke is already a rectangle; no outline storage is needed.
    func flatRectangleIfAxisAligned() throws(LayoutPathGeometryError) -> LayoutRect? {
        guard points.count == 2, points[0].x == points[1].x || points[0].y == points[1].y else { return nil }
        let extensions = try flatEndpointExtensions()
        let a = points[0], b = points[1], half = width / 2
        guard half > 0 else { throw .invalidValue }
        let rectangle: LayoutRect
        if a.y == b.y {
            let direction = b.x > a.x ? 1.0 : -1.0
            let start = a.x - direction * extensions.begin, end = b.x + direction * extensions.end
            rectangle = .init(origin: .init(x: min(start, end), y: a.y - half),
                              size: .init(width: abs(end - start), height: width))
        } else {
            let direction = b.y > a.y ? 1.0 : -1.0
            let start = a.y - direction * extensions.begin, end = b.y + direction * extensions.end
            rectangle = .init(origin: .init(x: a.x - half, y: min(start, end)),
                              size: .init(width: width, height: abs(end - start)))
        }
        guard rectangle.minX.isFinite, rectangle.minY.isFinite, rectangle.maxX.isFinite, rectangle.maxY.isFinite,
              rectangle.size.width.isFinite, rectangle.size.height.isFinite,
              rectangle.maxX > rectangle.minX, rectangle.maxY > rectangle.minY else { throw .invalidValue }
        return rectangle
    }

    /// Offset-line miter intersections; circular endpoints require a curve representation.
    public func flatOutline() throws(LayoutPathGeometryError) -> LayoutPolygon {
        if let rectangle = try flatRectangleIfAxisAligned() { return rectangle.toPolygon() }
        let extensions = try flatEndpointExtensions()
        let half = width / 2
        guard half > 0 else { throw .invalidValue }
        var directions: [LayoutPoint] = []
        directions.reserveCapacity(points.count - 1)
        for index in 1..<points.count {
            let dx = points[index].x - points[index - 1].x
            let dy = points[index].y - points[index - 1].y
            let length = hypot(dx, dy)
            guard length.isFinite, length > 0 else { throw .degenerateSegment }
            directions.append(.init(x: dx / length, y: dy / length))
        }
        var left: [LayoutPoint] = [], right: [LayoutPoint] = []
        left.reserveCapacity(points.count); right.reserveCapacity(points.count)
        for index in points.indices {
            var center = points[index]
            let offset: LayoutPoint
            if index == 0 || index == points.count - 1 {
                let direction = index == 0 ? directions[0] : directions[directions.count - 1]
                let distance = index == 0 ? -extensions.begin : extensions.end
                center = .init(x: center.x + direction.x * distance, y: center.y + direction.y * distance)
                offset = .init(x: -direction.y * half, y: direction.x * half)
            } else {
                let a = directions[index - 1], b = directions[index]
                let denominator = 1 + a.x * b.x + a.y * b.y
                guard denominator > 0 else { throw .immediateReversal }
                offset = .init(x: -(a.y + b.y) * half / denominator,
                               y: (a.x + b.x) * half / denominator)
            }
            let l = LayoutPoint(x: center.x + offset.x, y: center.y + offset.y)
            let r = LayoutPoint(x: center.x - offset.x, y: center.y - offset.y)
            guard l.x.isFinite, l.y.isFinite, r.x.isFinite, r.y.isFinite, l != r else { throw .invalidValue }
            left.append(l); right.append(r)
        }
        left.append(contentsOf: right.reversed())
        return .init(points: left)
    }
}
