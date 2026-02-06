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
            return .path(LayoutPath(points: points, width: path.width))
        }
    }
}
