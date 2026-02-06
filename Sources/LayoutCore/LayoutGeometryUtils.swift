import Foundation

public struct LayoutGeometryUtils {
    public static func boundingBox(for geometry: LayoutGeometry) -> LayoutRect {
        switch geometry {
        case .rect(let rect):
            return rect
        case .polygon(let polygon):
            return boundingBox(for: polygon)
        case .path(let path):
            return boundingBox(for: path)
        }
    }

    public static func boundingBox(for polygon: LayoutPolygon) -> LayoutRect {
        guard let first = polygon.points.first else {
            return .zero
        }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for p in polygon.points.dropFirst() {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    public static func boundingBox(for path: LayoutPath) -> LayoutRect {
        guard let first = path.points.first else { return .zero }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for p in path.points.dropFirst() {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        let half = path.width / 2
        return LayoutRect(
            origin: LayoutPoint(x: minX - half, y: minY - half),
            size: LayoutSize(width: (maxX - minX) + 2 * half, height: (maxY - minY) + 2 * half)
        )
    }

    public static func segments(for geometry: LayoutGeometry) -> [LayoutSegment] {
        switch geometry {
        case .rect(let rect):
            return segments(for: rect)
        case .polygon(let polygon):
            return segments(for: polygon)
        case .path(let path):
            return segments(for: path)
        }
    }

    public static func segments(for rect: LayoutRect) -> [LayoutSegment] {
        let p1 = LayoutPoint(x: rect.minX, y: rect.minY)
        let p2 = LayoutPoint(x: rect.maxX, y: rect.minY)
        let p3 = LayoutPoint(x: rect.maxX, y: rect.maxY)
        let p4 = LayoutPoint(x: rect.minX, y: rect.maxY)
        return [
            LayoutSegment(start: p1, end: p2),
            LayoutSegment(start: p2, end: p3),
            LayoutSegment(start: p3, end: p4),
            LayoutSegment(start: p4, end: p1),
        ]
    }

    public static func segments(for polygon: LayoutPolygon) -> [LayoutSegment] {
        guard polygon.points.count >= 2 else { return [] }
        var segments: [LayoutSegment] = []
        for i in 0..<(polygon.points.count - 1) {
            segments.append(LayoutSegment(start: polygon.points[i], end: polygon.points[i + 1]))
        }
        if let first = polygon.points.first, let last = polygon.points.last {
            segments.append(LayoutSegment(start: last, end: first))
        }
        return segments
    }

    public static func segments(for path: LayoutPath) -> [LayoutSegment] {
        guard path.points.count >= 2 else { return [] }
        var segments: [LayoutSegment] = []
        for i in 0..<(path.points.count - 1) {
            segments.append(LayoutSegment(start: path.points[i], end: path.points[i + 1]))
        }
        return segments
    }

    public static func minimumDistance(between a: LayoutGeometry, and b: LayoutGeometry) -> Double {
        let segmentsA = segments(for: a)
        let segmentsB = segments(for: b)
        guard !segmentsA.isEmpty, !segmentsB.isEmpty else { return .infinity }

        var minDistance = Double.greatestFiniteMagnitude
        for s1 in segmentsA {
            for s2 in segmentsB {
                let dist = distanceBetweenSegments(s1, s2)
                minDistance = min(minDistance, dist)
            }
        }

        let inflateA = pathInflation(for: a)
        let inflateB = pathInflation(for: b)
        let adjusted = minDistance - inflateA - inflateB
        return max(0, adjusted)
    }

    public static func intersects(_ a: LayoutGeometry, _ b: LayoutGeometry) -> Bool {
        if minimumDistance(between: a, and: b) == 0 {
            return true
        }
        return false
    }

    public static func contains(_ point: LayoutPoint, in geometry: LayoutGeometry) -> Bool {
        switch geometry {
        case .rect(let rect):
            return rect.contains(point)
        case .polygon(let polygon):
            return pointInPolygon(point, polygon: polygon)
        case .path(let path):
            return distanceToPath(point, path: path) <= path.width / 2
        }
    }

    public static func area(of geometry: LayoutGeometry) -> Double {
        switch geometry {
        case .rect(let rect):
            return rect.size.width * rect.size.height
        case .polygon(let polygon):
            return polygonArea(polygon)
        case .path(let path):
            return pathLength(path) * path.width
        }
    }

    public static func polygonArea(_ polygon: LayoutPolygon) -> Double {
        guard polygon.points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<polygon.points.count {
            let p1 = polygon.points[i]
            let p2 = polygon.points[(i + 1) % polygon.points.count]
            sum += (p1.x * p2.y - p2.x * p1.y)
        }
        return abs(sum) * 0.5
    }

    public static func pathLength(_ path: LayoutPath) -> Double {
        guard path.points.count >= 2 else { return 0 }
        var length = 0.0
        for i in 0..<(path.points.count - 1) {
            length += distance(path.points[i], path.points[i + 1])
        }
        return length
    }

    public static func distance(_ a: LayoutPoint, _ b: LayoutPoint) -> Double {
        hypot(b.x - a.x, b.y - a.y)
    }

    public static func distanceBetweenSegments(_ s1: LayoutSegment, _ s2: LayoutSegment) -> Double {
        if segmentsIntersect(s1, s2) {
            return 0
        }
        let d1 = distancePointToSegment(s1.start, s2)
        let d2 = distancePointToSegment(s1.end, s2)
        let d3 = distancePointToSegment(s2.start, s1)
        let d4 = distancePointToSegment(s2.end, s1)
        return min(min(d1, d2), min(d3, d4))
    }

    public static func distancePointToSegment(_ p: LayoutPoint, _ segment: LayoutSegment) -> Double {
        let v = vector(from: segment.start, to: segment.end)
        let w = vector(from: segment.start, to: p)
        let c1 = dot(w, v)
        if c1 <= 0 {
            return distance(p, segment.start)
        }
        let c2 = dot(v, v)
        if c2 <= c1 {
            return distance(p, segment.end)
        }
        let b = c1 / c2
        let pb = LayoutPoint(x: segment.start.x + b * v.x, y: segment.start.y + b * v.y)
        return distance(p, pb)
    }

    public static func segmentsIntersect(_ s1: LayoutSegment, _ s2: LayoutSegment) -> Bool {
        let d1 = direction(s1.start, s1.end, s2.start)
        let d2 = direction(s1.start, s1.end, s2.end)
        let d3 = direction(s2.start, s2.end, s1.start)
        let d4 = direction(s2.start, s2.end, s1.end)

        if d1 == 0 && onSegment(s1.start, s1.end, s2.start) { return true }
        if d2 == 0 && onSegment(s1.start, s1.end, s2.end) { return true }
        if d3 == 0 && onSegment(s2.start, s2.end, s1.start) { return true }
        if d4 == 0 && onSegment(s2.start, s2.end, s1.end) { return true }

        return (d1 > 0 && d2 < 0 || d1 < 0 && d2 > 0) &&
            (d3 > 0 && d4 < 0 || d3 < 0 && d4 > 0)
    }

    public static func pointInPolygon(_ point: LayoutPoint, polygon: LayoutPolygon) -> Bool {
        guard polygon.points.count >= 3 else { return false }
        var inside = false
        var j = polygon.points.count - 1
        for i in 0..<polygon.points.count {
            let pi = polygon.points[i]
            let pj = polygon.points[j]
            if ((pi.y > point.y) != (pj.y > point.y)) &&
                (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y + 1e-12) + pi.x) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    public static func distanceToPath(_ point: LayoutPoint, path: LayoutPath) -> Double {
        let segments = segments(for: path)
        var minDistance = Double.greatestFiniteMagnitude
        for segment in segments {
            minDistance = min(minDistance, distancePointToSegment(point, segment))
        }
        return minDistance
    }

    public static func minimumWidth(of geometry: LayoutGeometry) -> Double {
        switch geometry {
        case .rect(let rect):
            return min(rect.size.width, rect.size.height)
        case .path(let path):
            return path.width
        case .polygon(let polygon):
            return minimumPolygonWidth(polygon)
        }
    }

    public static func minimumPolygonWidth(_ polygon: LayoutPolygon) -> Double {
        let segments = segments(for: polygon)
        guard segments.count >= 2 else { return 0 }
        var minWidth = Double.greatestFiniteMagnitude
        for i in 0..<segments.count {
            let a = segments[i]
            let directionA = vector(from: a.start, to: a.end)
            for j in (i + 1)..<segments.count {
                let b = segments[j]
                let directionB = vector(from: b.start, to: b.end)
                if isParallel(directionA, directionB) {
                    let dist = distanceBetweenSegments(a, b)
                    minWidth = min(minWidth, dist)
                }
            }
        }
        if minWidth == Double.greatestFiniteMagnitude {
            return 0
        }
        return minWidth
    }

    private static func vector(from a: LayoutPoint, to b: LayoutPoint) -> LayoutPoint {
        LayoutPoint(x: b.x - a.x, y: b.y - a.y)
    }

    private static func dot(_ a: LayoutPoint, _ b: LayoutPoint) -> Double {
        a.x * b.x + a.y * b.y
    }

    private static func direction(_ a: LayoutPoint, _ b: LayoutPoint, _ c: LayoutPoint) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func onSegment(_ a: LayoutPoint, _ b: LayoutPoint, _ c: LayoutPoint) -> Bool {
        min(a.x, b.x) <= c.x && c.x <= max(a.x, b.x) &&
        min(a.y, b.y) <= c.y && c.y <= max(a.y, b.y)
    }

    private static func isParallel(_ a: LayoutPoint, _ b: LayoutPoint) -> Bool {
        abs(a.x * b.y - a.y * b.x) < 1e-9
    }

    private static func pathInflation(for geometry: LayoutGeometry) -> Double {
        switch geometry {
        case .path(let path):
            return path.width / 2
        default:
            return 0
        }
    }
}
