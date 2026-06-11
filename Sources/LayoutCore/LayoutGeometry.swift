import Foundation

public enum LayoutGeometry: Hashable, Sendable, Codable {
    case rect(LayoutRect)
    case polygon(LayoutPolygon)
    case path(LayoutPath)

    private enum CodingKeys: String, CodingKey {
        case kind
        case rect
        case polygon
        case path
    }

    private enum Kind: String, Codable {
        case rect
        case polygon
        case path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .rect:
            let rect = try container.decode(LayoutRect.self, forKey: .rect)
            self = .rect(rect)
        case .polygon:
            let polygon = try container.decode(LayoutPolygon.self, forKey: .polygon)
            self = .polygon(polygon)
        case .path:
            let path = try container.decode(LayoutPath.self, forKey: .path)
            self = .path(path)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rect(let rect):
            try container.encode(Kind.rect, forKey: .kind)
            try container.encode(rect, forKey: .rect)
        case .polygon(let polygon):
            try container.encode(Kind.polygon, forKey: .kind)
            try container.encode(polygon, forKey: .polygon)
        case .path(let path):
            try container.encode(Kind.path, forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}

public extension LayoutGeometry {
    func transformed(by transform: LayoutTransform) -> LayoutGeometry {
        switch self {
        case .rect(let rect):
            let corners = [
                LayoutPoint(x: rect.minX, y: rect.minY),
                LayoutPoint(x: rect.maxX, y: rect.minY),
                LayoutPoint(x: rect.maxX, y: rect.maxY),
                LayoutPoint(x: rect.minX, y: rect.maxY),
            ].map { transform.apply(to: $0) }
            return .polygon(LayoutPolygon(points: corners))
        case .polygon(let polygon):
            let points = polygon.points.map { transform.apply(to: $0) }
            return .polygon(LayoutPolygon(points: points))
        case .path(let path):
            let points = path.points.map { transform.apply(to: $0) }
            return .path(LayoutPath(points: points, width: path.width, endCap: path.endCap))
        }
    }

    /// The geometry rotated a quarter turn about a pivot, preserving its
    /// kind: an axis-aligned rect stays a rect (width and height swap), a
    /// path keeps its width and end cap. Unlike ``transformed(by:)``,
    /// which canonicalizes to polygons, a 90-degree turn never needs that
    /// loss of form.
    func rotated90(around pivot: LayoutPoint, clockwise: Bool) -> LayoutGeometry {
        func rotate(_ p: LayoutPoint) -> LayoutPoint {
            let dx = p.x - pivot.x
            let dy = p.y - pivot.y
            return clockwise
                ? LayoutPoint(x: pivot.x + dy, y: pivot.y - dx)
                : LayoutPoint(x: pivot.x - dy, y: pivot.y + dx)
        }
        switch self {
        case .rect(let rect):
            let a = rotate(LayoutPoint(x: rect.minX, y: rect.minY))
            let b = rotate(LayoutPoint(x: rect.maxX, y: rect.maxY))
            return .rect(LayoutRect(
                origin: LayoutPoint(x: min(a.x, b.x), y: min(a.y, b.y)),
                size: LayoutSize(width: abs(a.x - b.x), height: abs(a.y - b.y))
            ))
        case .polygon(let polygon):
            return .polygon(LayoutPolygon(points: polygon.points.map(rotate)))
        case .path(let path):
            return .path(LayoutPath(
                points: path.points.map(rotate),
                width: path.width,
                endCap: path.endCap
            ))
        }
    }

    /// The geometry mirrored across an axis line through a point,
    /// preserving its kind. Polygon point order is reversed so the
    /// winding orientation survives the reflection.
    func mirrored(across axis: LayoutMirrorAxis, through center: LayoutPoint) -> LayoutGeometry {
        func mirror(_ p: LayoutPoint) -> LayoutPoint {
            switch axis {
            case .vertical: return LayoutPoint(x: 2 * center.x - p.x, y: p.y)
            case .horizontal: return LayoutPoint(x: p.x, y: 2 * center.y - p.y)
            }
        }
        switch self {
        case .rect(let rect):
            let a = mirror(LayoutPoint(x: rect.minX, y: rect.minY))
            let b = mirror(LayoutPoint(x: rect.maxX, y: rect.maxY))
            return .rect(LayoutRect(
                origin: LayoutPoint(x: min(a.x, b.x), y: min(a.y, b.y)),
                size: rect.size
            ))
        case .polygon(let polygon):
            return .polygon(LayoutPolygon(points: polygon.points.map(mirror).reversed()))
        case .path(let path):
            return .path(LayoutPath(
                points: path.points.map(mirror),
                width: path.width,
                endCap: path.endCap
            ))
        }
    }

    /// The geometry shifted by a vector, preserving its kind: a rect stays
    /// a rect, a path keeps its width and end cap. Unlike
    /// ``transformed(by:)``, which canonicalizes to polygons for general
    /// transforms, translation never needs that loss of form.
    func translated(by delta: LayoutPoint) -> LayoutGeometry {
        switch self {
        case .rect(let rect):
            return .rect(LayoutRect(origin: rect.origin.translated(by: delta), size: rect.size))
        case .polygon(let polygon):
            return .polygon(LayoutPolygon(points: polygon.points.map { $0.translated(by: delta) }))
        case .path(let path):
            return .path(LayoutPath(
                points: path.points.map { $0.translated(by: delta) },
                width: path.width,
                endCap: path.endCap
            ))
        }
    }
}
